var foo = function(a) 
/*: (a:Ref) / (a: Top > a.pro) -> Top / sameExact */
{

};

/*: (~arr: Arr(Int) > lArrPro) */ "#weak";

var baz = function() /*: () -> Top  */ { };

var bar = function(a,b)
/*: [;L] (Ref(L), Bool) / (L: Arr(Int) > lArrPro) -> Top / () */ 

{

  /*: a (~arr, frzn) */ "#freeze";
  var vv =  a;

  if (b) {
    var tmp = /*: l1 Arr(Int) */ [];    
    /*: tmp (~arr, frzn) */ "#freeze";
    vv = tmp;
  };

  //assume(vv != null);
  //baz();
  
  /*: vv ltotal */ "#thaw";
  assume(vv != null);
  /*: [;ltotal,lArrPro] */  foo(vv);
  /*: vv (~arr, thwd ltotal) */ "#freeze";

};

