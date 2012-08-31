
var mammal = function(priv) /*: ty_init_mammal */ {
  var x = /*: Lnew */ {};
  x.get_name = function() /*: ty_get_name */ {
    return priv.name;
  };
  return x;
};

/*: #define ty_priv {Dict|(objsel [v] "name" [Heap] lObjPro : Str)} */ '#define';

/*: #define ty_init_mammal [;Lnew,Lpriv;Heap]
      [[priv:Ref(Lpriv)]]
    / [Heap ++ lObjPro |-> (do:Dict,lROOT), Lpriv |-> (dPriv:ty_priv,lObjPro)]
   -> Ref(Lnew) / [Heap ++ lObjPro |-> same, Lpriv |-> same,
                   &priv |-> _:Ref(Lpriv),
                   Lnew |-> (dNew:ty_mam, lObjPro)] */ '#define';

/*: #define ty_mam {Dict|(and (dom v {"get_name"})
                              ((sel v "get_name") : ty_get_name))} */ '#define';

/*: #define ty_get_name [;Dummy1;Heap]
      [[this:Ref(Dummy1)]]
    / [Heap ++ Lpriv |-> (ePriv:ty_priv,lObjPro), &priv |-> __:Ref(Lpriv)]
   -> {(= v (objsel [ePriv] "name" [Heap] lObjPro))} / same */ '#define';

var herbPriv = /*: lHerbPriv */ {name: "Herb"};
var herb     = /*: [;lHerb,lHerbPriv;] */ mammal(herbPriv);
var oldName  = herb.get_name();

assert (oldName === "Herb");

herbPriv.name = "Herbert";
var newName   = herb.get_name();

assert (newName === "Herbert");


var cat = function(priv2) /*: ty_init_cat */ {
  var obj = /*: [;Lnew,Lpriv;] */ mammal(priv2);
  obj.purr = function() /*: ty_sound */ { return "purr"; };
  return obj;
};

/*: #define ty_init_cat [;Lnew,Lpriv;Heap]
        [[priv2:Ref(Lpriv)]] / [Heap ++ lObjPro |-> (do:Dict,lROOT),
                                &mammal |-> _:ty_init_mammal,
                                Lpriv   |-> (dPriv:ty_priv,lObjPro)]
     -> Ref(Lnew) / [Heap ++ lObjPro |-> same, Lpriv |-> same, &mammal |-> same,
                             &priv   |-> _:Ref(Lpriv),
                             Lnew    |-> (dNew:ty_cat, lObjPro)] */ '#define';

/*: #define ty_cat {(and (= (tag v) "Dict") (dom v {"get_name","purr"})
                         ((sel v "get_name") : ty_get_name)
                         ((sel v "purr") : ty_sound))} */ '#define';

/*: #define ty_sound [;L1;] [[this:Ref(L1)]] -> Str */ '#define';

