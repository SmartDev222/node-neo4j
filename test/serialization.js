/*** Generated by streamline --lines-mark 0.1.11 - DO NOT EDIT ***/

var __global = typeof global !== 'undefined' ? global : window;
function __future(fn, args, i) { if (!fn) throw new Error("anonymous function requires callback"); var done, err, result; var cb = function(e, r) { done = true; err = e, result = r; }; args = Array.prototype.slice.call(args); args[i] = function(e, r) { cb(e, r); }; fn.apply(this, args); return function(_) { if (typeof _ !== "function") throw new Error("future requires callback"); if (done) _.call(this, err, result); else cb = _.bind(this); }.bind(this); }
/*     1 */ var assert = require("assert");
/*     6 */ var db = require("./setup");
/*     7 */ var neo4j = require("../lib/neo4j");
/*    11 */ var data = {
/*    12 */   name: "Daniel Gasienica",
/*    13 */   magicNumber: 42,
/*    14 */   lovesIceCream: true
            };
/*    17 */ var newData = {
/*    18 */   name: "Daniel Gasienica",
/*    19 */   father: {
/*    20 */     firstName: "Jan",
/*    21 */     lastName: "Gasienica"
              },
/*    23 */   tired: false
            };
/*    28 */ function transform(o) {
/*    29 */   return neo4j.deserialize(neo4j.serialize(o));
            };
/*    34 */ module.exports = function __1(beforeExit, _) {
              if (!_) {
                return __future(__1, arguments, 1);
              }
            ;
              var __ = _;
/*    36 */   assert.deepEqual(transform(data), data);
/*    37 */   assert.deepEqual(transform(newData), newData);
/*    39 */   var o;
/*    42 */   o = 1;
/*    43 */   assert.strictEqual(transform(o), o);
/*    46 */   o = "gasi";
/*    47 */   assert.strictEqual(transform(o), o);
/*    50 */   o = true;
/*    51 */   assert.strictEqual(transform(o), o);
/*    54 */   o = [true,false,true,];
/*    55 */   assert.throws(transform(o));
/*    58 */   o = {
/*    58 */     "this.that": "shouldn't work"
              };
/*    59 */   assert.notDeepEqual(transform(o), o);
              return __();
            };
