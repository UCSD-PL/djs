/*: "tests/djs/sif/__sif.dref" */ "#use";



///*: (forall (s) (implies (isPublic s) (isSecret s))) */ "#assume";

var public = /*: {(isSecret v)} */ "#extern";
//var public /*: {(isPublic v)} */ = "#extern";
//var public;

var bar = function(window, x, secret, p) 
/*: [A;L;] (Ref(~window), Ref(L), {A|(isSecret v)}, {A|(isPublic v)})
    / (L: {Dict|(implies (has v "foo") ((sel v "foo")::A))} > lObjPro) 
    -> Top / sameType */ 
{
  
  var obj = {};

  obj.__proto__ = x; 

  assert(/*: {(isSecret v)} */ (secret));
  
  x.foo = secret;

  assert(/*: {(isSecret v)} */ (obj.foo));
  
  window.p = obj.foo;
};


