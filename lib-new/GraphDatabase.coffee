$ = require 'underscore'
assert = require 'assert'
{Error} = require './errors'
lib = require '../package.json'
Node = require './Node'
Relationship = require './Relationship'
Request = require 'request'
Transaction = require './Transaction'
URL = require 'url'


module.exports = class GraphDatabase

    # Default HTTP headers:
    headers:
        'User-Agent': "node-neo4j/#{lib.version}"
        'X-Stream': 'true'

    constructor: (opts={}) ->
        if typeof opts is 'string'
            opts = {url: opts}

        {@url, @headers, @proxy, @agent} = opts

        if not @url
            throw new TypeError 'URL to Neo4j required'

        # TODO: Do we want to special-case User-Agent? Blacklist X-Stream?
        @headers or= {}
        $(@headers).defaults @constructor::headers

    http: (opts={}, cb) ->
        if typeof opts is 'string'
            opts = {path: opts}

        {method, path, headers, body, raw} = opts

        if not path
            throw new TypeError 'Path required'

        method or= 'GET'
        headers or= {}

        # TODO: Would be good to test custom proxy and agent, but difficult.
        # Same with Neo4j returning gzipped responses (e.g. through an LB).
        req = Request
            method: method
            url: URL.resolve @url, path
            proxy: @proxy
            headers: $(headers).defaults @headers
            agent: @agent
            json: body ? true
            gzip: true  # This is only for responses: decode if gzipped.

        # Important: only pass a callback to Request if a callback was passed
        # to us. This prevents Request from doing unnecessary JSON parse work
        # if the caller prefers to stream the response instead of buffer it.
        , cb and (err, resp) =>
            if err
                # TODO: Do we want to wrap or modify native errors?
                return cb err

            if raw
                # TODO: Do we want to return our own Response object?
                return cb null, resp

            if err = Error._fromResponse resp
                return cb err

            cb null, _transform resp.body

        # Instead of leaking our (third-party) Request instance, make sure to
        # explicitly return only its internal native ClientRequest instance.
        # https://github.com/request/request/blob/v2.53.1/request.js#L904
        # This is only populated when the request is `start`ed, so `start` it!
        req.start()
        req.req

    cypher: (opts={}, cb, _tx) ->
        if typeof opts is 'string'
            opts = {query: opts}

        if opts instanceof Array
            opts = {queries: opts}

        {queries, query, params, headers, lean, commit, rollback} = opts

        if not _tx and rollback
            throw new Error 'Illegal state: rolling back without a transaction!'

        if commit and rollback
            throw new Error 'Illegal state: both committing and rolling back!'

        if rollback and (query or queries)
            throw new Error 'Illegal state: rolling back with query/queries!'

        if not _tx and commit is false
            throw new TypeError 'Can’t refuse to commit without a transaction!
                To begin a new transaction without committing, call
                `db.beginTransaction()`, and then call `cypher` on that.'

        if not _tx and not (query or queries)
            throw new TypeError 'Query or queries required'

        if query and queries
            throw new TypeError 'Can’t supply both a single query
                and a batch of queries! Do you have a bug in your code?'

        if queries and params
            throw new TypeError 'When batching multiple queries,
                params must be supplied with each query, not globally.'

        if queries and lean
            throw new TypeError 'When batching multiple queries,
                `lean` must be specified with each query, not globally.'

        if (commit or rollback) and not (query or queries) and not _tx._id
            # (Note that we've already required query or queries if no
            # transaction present, so this means a transaction is present.)
            # This transaction hasn't even been created yet from Neo4j's POV
            # (because transactions are created lazily), so nothing to do.
            cb null, null
            return

        method = 'POST'
        method = 'DELETE' if rollback

        path = '/db/data/transaction'
        path += "/#{_tx._id}" if _tx?._id
        path += "/commit" if commit or not _tx

        # Normalize input query or queries to an array of queries always,
        # but remember whether a single query was given (not a batch).
        # Also handle the case where no queries were given; this is either a
        # void action (e.g. rollback), or legitimately an empty batch.
        if query
            queries = [{query, params, lean}]
            single = true
        else
            single = not queries    # void action, *not* empty [] given
            queries or= []

        # Generate the request body by transforming each query (which is
        # potentially a simple string) into Neo4j's `statement` format.
        # We need to remember what result format we requested for each query.
        formats = []
        body =
            statements:
                for query in queries
                    if typeof query is 'string'
                        query = {query}

                    if query.headers
                        throw new TypeError 'When batching multiple queries,
                            custom request headers cannot be supplied per query;
                            they must be supplied globally.'

                    {query, params, lean} = query

                    # NOTE: Lowercase 'rest' matters here for parsing.
                    formats.push format = if lean then 'row' else 'rest'

                    statement: query
                    parameters: params or {}
                    resultDataContents: [format]

        # TODO: Support streaming!
        #
        # NOTE: Specifying `raw: true` to save on parsing work (see `_transform`
        # helper at the bottom of this file) if any queries are `lean: true`.
        # Easy enough for us to parse ourselves, which we do, when needed.
        #
        @http {method, path, headers, body, raw: true}, (err, resp) =>

            if err
                # TODO: Do we want to wrap or modify native errors?
                # NOTE: This includes our own errors for non-2xx responses.
                return cb err

            if err = Error._fromResponse resp
                return cb err

            _tx?._updateFromResponse resp

            {results, errors} = resp.body

            # Parse any results first, before errors, in case this is a batch
            # request, where we want to return results alongside errors.
            # The top-level `results` is an array of results corresponding to
            # the `statements` (queries) inputted.
            # We want to transform each query's results from Neo4j's complex
            # format to a simple array of dictionaries.
            results =
                for result, i in results
                    {columns, data} = result
                    format = formats[i]

                    # The `data` for each query is an array of rows, but each of
                    # its elements is actually a dictionary of results keyed by
                    # response format. We only request one format per query.
                    # The value of each format is an array of rows, where each
                    # row is an array of column values. We transform those rows
                    # into dictionaries keyed by column names. Finally, we also
                    # parse nodes & relationships into object instances if this
                    # query didn't request a raw format. Phew!
                    $(data).pluck(format).map (row) ->
                        result = {}

                        for column, j in columns
                            result[column] = row[j]

                        if format is 'rest'
                            result = _transform result

                        result

            # What exactly we return depends on how we were called:
            #
            # - Batch: if an array of queries were given, we always return an
            #   array of each query's results.
            #
            # - Single: if a single query was given, we always return just that
            #   query's results.
            #
            # - Void: if neither was given, we explicitly return null.
            #   This is for transaction actions, e.g. commit, rollback, renew.
            #
            # We're already set up for the batch case by default, so we only
            # need to account for the other cases.
            #
            if single
                # This means a batch of queries was *not* given, but we still
                # normalized to an array of queries...
                if queries.length
                    # This means a single query was given:
                    assert.equal queries.length, 1,
                        'There should be *exactly* one query given.'
                    assert results.length <= 1,
                        'There should be *at most* one set of results.'
                    results = results[0]
                else
                    # This means no query was given:
                    assert.equal results.length, 0,
                        'There should be *no* results.'
                    results = null

            if errors.length
                # TODO: Is it possible to get back more than one error?
                # If so, is it fine for us to just use the first one?
                [error] = errors
                err = Error._fromTransaction error

            cb err, results

    beginTransaction: ->
        new Transaction @


    ## SCHEMA

    getLabels: (cb) ->
        # This endpoint returns the array of labels directly:
        # http://neo4j.com/docs/stable/rest-api-node-labels.html#rest-api-list-all-labels
        # Hence passing the callback directly. `http` handles 4xx, 5xx errors.
        # TODO: Would it be better for us to handle other non-200 responses too?
        @http
            method: 'GET'
            path: '/db/data/labels'
        , cb

    getPropertyKeys: (cb) ->
        # This endpoint returns the array of property keys directly:
        # http://neo4j.com/docs/stable/rest-api-property-values.html#rest-api-list-all-property-keys
        # Hence passing the callback directly. `http` handles 4xx, 5xx errors.
        # TODO: Would it be better for us to handle other non-200 responses too?
        @http
            method: 'GET'
            path: '/db/data/propertykeys'
        , cb

    getRelationshipTypes: (cb) ->
        # This endpoint returns the array of relationship types directly:
        # http://neo4j.com/docs/stable/rest-api-relationship-types.html#rest-api-get-relationship-types
        # Hence passing the callback directly. `http` handles 4xx, 5xx errors.
        # TODO: Would it be better for us to handle other non-200 responses too?
        @http
            method: 'GET'
            path: '/db/data/relationship/types'
        , cb

    # TODO: Indexes
    # TODO: Constraints
    # TODO: Legacy indexing


## HELPERS

#
# Deep inspects the given object -- which could be a simple primitive, a map,
# an array with arbitrary other objects, etc. -- and transforms any objects that
# look like nodes and relationships into Node and Relationship instances.
# Returns the transformed object, and does not mutate the input object.
#
_transform = (obj) ->
    # Nothing to transform for primitives and null:
    if (not obj) or (typeof obj isnt 'object')
        return obj

    # Process arrays:
    # (NOTE: Not bothering to detect arrays made in other JS contexts.)
    if obj instanceof Array
        return obj.map _transform

    # Feature-detect (AKA "duck-type") Node & Relationship objects, by simply
    # trying to parse them as such.
    # Important: check relationships first, for precision/specificity.
    # TODO: If we add a Path class, we'll need to check for that here too.
    if rel = Relationship._fromRaw obj
        return rel
    if node = Node._fromRaw obj
        return node

    # Otherwise, process as a dictionary/map:
    map = {}
    for key, val of obj
        map[key] = _transform val
    map
