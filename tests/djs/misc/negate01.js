var negate = function(x) /*: [[x:NumOrBool]] -> {(ite (x:Num) (v:Num) (v:Bool))} */ {
  x = (typeof(x) == "number") ? 0 - x : !x;
  return x;
};

assert (typeof (negate(1)) == "number");
assert (typeof (negate(true)) == "boolean");
