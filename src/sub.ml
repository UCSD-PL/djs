
open Lang
open LangUtils

let doMeet        = ref false
let maxJoinSize   = ref 1 (* anything <= 1 means not doing joins *)


(***** Collecting type terms, or "boxes" **************************************)

let typeTermsTyp acc t =
  foldForm (fun acc -> function
    | PUn(HasTyp(_,u)) -> TypeTerms.add u acc
    | _                -> acc
  ) acc t

let typeTerms g =
  let init = TypeTerms.singleton UNull in
  List.fold_left (fun acc -> function
    | Var(x,t) ->
        (* since foldForm takes a type, jumping through TRefinement hoop *)
        let p = applyTyp t (wVar x) in
        typeTermsTyp acc (TRefinement ("DUMMY TYPE TERMS", p))
    | _ ->
        acc
  ) init g


(***** Meet/Join **************************************************************)

let meet u1 u2 = failwith "meet nyi"

let join u1 u2 = failwith "join nyi"

let combineArrows f boxes =
  TypeTerms.fold (fun ut acc ->
    match ut, acc with
      | UArr _, None    -> Some ut
      | UArr _, Some(u) -> Some (f ut u)
      | _               -> acc
  ) boxes None

let meetAll = combineArrows meet
let joinAll = combineArrows join


(***** Type extraction, or "unboxing" *****************************************)

let boxNumbers s = 
  let l = TypeTerms.elements s in
(*
  let il = List.map (Utils.IdTable.getId idTypTerms) l in
*)
  let il =
    List.map (function ut ->
      try Utils.IdTable.getId idTypTerms ut
      with Not_found -> failwith (spr "Sub.boxNumbers:\n\n %s" (prettyStrTT ut))
(*
      with Not_found -> begin
        Log.warn (spr "adding box from Sub: %s\n" (prettyStrTT ut));
        Utils.IdTable.process idTypTerms ut
      end
*)
    ) l in
  il

let setUpExtract t usedBoxes =
  let x = freshVar "extract" in
  Zzz.pushScope ();
  Zzz.addBinding x (applyTyp t (wVar x));
  Zzz.dump (spr "; off limits: %s" (Utils.strIntList (boxNumbers usedBoxes)));
  Zzz.doingExtract := true;
  x

let tearDownExtract () =
  Zzz.doingExtract := false;
  Zzz.removeBinding ();
  Zzz.popScope ();
  ()

let mustFlow_ usedBoxes ?filter:(f=(fun _ -> true)) g t =
  Log.smallTitle "MustFlow";
  let boxes = TypeTerms.diff (typeTerms g) usedBoxes in
  let boxes = TypeTerms.filter f boxes in
  let x = setUpExtract t usedBoxes in
  let extracted =
    TypeTerms.fold
      (fun ut acc ->
         if Zzz.checkValid "mustFlow" (hastyp (wVar x) ut)
           then TypeTerms.add ut acc
           else acc)
      boxes
      TypeTerms.empty
  in
  tearDownExtract ();
  let il = boxNumbers extracted in
  Zzz.dump (spr "; extracted: is(%s, %s)" x (Utils.strIntList il));
  Log.log (spr "%s\n" (Utils.strIntList il));
  extracted

let canFlow_ usedBoxes ?filter:(f=(fun _ -> true)) g t =
  Log.smallTitle "CanFlow";
  let boxes = TypeTerms.diff (typeTerms g) usedBoxes in
  let boxes = TypeTerms.filter f boxes in
  let x = setUpExtract t usedBoxes in
(*
  (* subsets of size 2 to !maxJoinSize in increasing order of size *)
*)
  (* subsets of size 1 to !maxJoinSize in increasing order of size *)
  let subsets =
    boxes
    |> TypeTerms.elements
    |> Utils.powersetMaxSize !maxJoinSize
    (* |> List.filter (fun l -> List.length l > 1) *)
    |> List.sort (fun l1 l2 -> List.length l1 - List.length l2)
  in
  let extracted =
    try
      List.find (function subset ->
        let upperBound = pOr (List.map (hastyp (wVar x)) subset) in
        Zzz.checkValid "canFlow" upperBound
      ) subsets
    with Not_found ->
      []
  in
  tearDownExtract ();
  mkTypeTerms extracted


(***** Heap Manipulation ******************************************************)

let simpleHeapJoin v h1 h2 =
  if h1 = h2 then h1
  (* TODO added 12/1 *)
  else if h1 = botHeap then h2
  else if h2 = botHeap then h1
  else
  printTcErr [(spr "simpleheapjoin:\n\n%s\n\n%s"
    (prettyStrHeap h1) (prettyStrHeap h2))]



(* TODO for now, copied and simplified from TcDref *)

let simpleTcAddBinding ?isNew:(isNew=true) x s g =
  Zzz.addBinding ~isNew x (applyTyp s (wVar x));
  let g' = Var(x,s)::g in
  g'

let simpleTcRemoveBinding () =
  Zzz.removeBinding ();
  ()

let simpleTcRemoveBindingN n =
  for i = 1 to n do simpleTcRemoveBinding () done


(* TODO can't directly use the version in TcDref, since that one uses
   tcAddBinding, which uses tryDestruct, which uses Sub.extraction *)

let simpleSnapshot cap g h =
  let l = List.map snd (snd h) in
  if l <> [] then Zzz.dump (spr "; snapshot added some bindings [%s]" cap);
  let (n,g1) = 
    List.fold_left (fun (k,acc) -> function
      | HConc(x,_) | HConcObj(x,_,_) -> (k+1, simpleTcAddBinding x tyAny acc)
    ) (0,g) l
  in
  let g2 = 
    List.fold_left (fun acc -> function
      | HConc(x,s) | HConcObj(x,s,_) -> simpleTcAddBinding ~isNew:false x s acc
    ) g1 l
  in
  (n, g2)


(***** Helpers ****************************************************************)

let checkLength s errList l1 l2 =
  if List.length l1 <> List.length l2
  then err (errList @ [spr "different number of %s args" s])
  else ()

type obligation =
  | OConc of vvar * typ

let heapSubstAndObligations errList cs1 cs2 =
  let foo (acc1,acc2) (l,hc2) =
    try begin
      let hc1 = snd (List.find (fun (l',_) -> l = l') cs1) in
      match hc1, hc2 with
        | HConc(y1,_), HConc(y2,s2) ->
            ((y2, wVar y1) :: acc1, OConc (y2, s2) :: acc2)
        | HConcObj(y1,_,l1'), HConcObj(y2,s2,l2') ->
            if l1' = l2' then
              ((y2, wVar y1) :: acc1, OConc (y2, s2) :: acc2)
            else
              err (errList @ [spr "proto links for [%s] differ:" (strLoc l);
                              spr "  %s" (strLoc l1');
                              spr "  %s" (strLoc l2')])
        | _ ->
            err (errList @ [spr
              "constraints for [%s] have different shape" (strLoc l)])
    end with Not_found ->
      err (errList @ [spr "no location constraint for [%s]" (strLoc l)])
  in
  List.fold_left foo ([],[]) cs2


(***** Subtyping **************************************************************)

let rec checkTypes errList usedBoxes g t1 t2 =
  let v = freshVar "v" in
  let (p1,p2) = (applyTyp t1 (wVar v), applyTyp t2 (wVar v)) in
  let (st1,st2) = (prettyStrTyp t1, prettyStrTyp t2) in
  let (sp1,sp2) = (prettyStrForm p1, prettyStrForm p2) in
  let errList =
    (* errList @ [spr "Sub.checkTypes:\n   t1 = %s\n   t2 = %s" st1 st2; *)
    errList @ [spr "Sub.checkTypes:\n   %s\n < %s" st1 st2;
               spr "Need to prove the implication:\n   %s\n=> %s" sp1 sp2]
  in
  Zzz.pushScope ();
  Zzz.addBinding v p1;
  checkFormula errList usedBoxes g p2;
  Zzz.popScope ()

and checkFormula errList usedBoxes g p =
  let clauses = Cnf.convert p in
  let n = List.length clauses in
  Utils.iter_i
    (fun (pi,qi) i ->
       Zzz.pushForm pi;
       let qForm = pOr (List.map (fun q -> PUn q) qi) in
       let (s1,s2) = (prettyStrForm pi, prettyStrForm qForm) in
       let errList =
         errList @ [spr "Clause %d/%d:\n   %s\n~> %s" (i+1) n s1 s2] in
       checkUnPreds errList usedBoxes g (qi,qForm);
       Zzz.popForm ())
    clauses

(* small optimization: qForm is qs lifted to a formula, since qForm is
   already computed by checkFormula for printing purposes *)
and checkUnPreds errList usedBoxes g (qs,qForm) =
  if Zzz.checkValid "" qForm then ()
  else if List.exists (checkUnPred errList usedBoxes g) qs then ()
  else err (errList @ ["Cannot discharge this clause."])

and checkUnPred errList usedBoxes g = function
  | HasTyp(w,u) -> checkHasTyp errList usedBoxes g w u 

and checkHasTyp errList usedBoxes g w u =
(*
  let errList =
    errList @ [spr "checkHasTyp %s :: %s" (prettyStrWal w) (prettyStrTT u)] in
*)

  if !maxJoinSize = 1 then begin
    let mustFlowBoxes = mustFlow_ usedBoxes g (ty(PEq(theV,w))) in
    let usedBoxes = TypeTerms.union usedBoxes mustFlowBoxes in
    let n = TypeTerms.cardinal mustFlowBoxes in
    if n = 0 then err (errList @ [spr "0 boxes must-flow to %s" (prettyStrWal w)])
    else if n > 0 && !doMeet then err (errList @ ["meet nyi"])
    else TypeTerms.exists
           (function u' -> checkTypeTerms errList usedBoxes g u' u)
           mustFlowBoxes

  end else begin
    let smallestCanFlowSet = canFlow_ usedBoxes g (ty(PEq(theV,w))) in
    ignore smallestCanFlowSet;
    err (errList @ ["join nyi!"])
  end

and checkTypeTerms errList usedBoxes g u1 u2 =
  sugarArrow := false;
  let errList =
    errList @ [spr "checkTypeTerms:\n   %s\n<: %s"
                 (prettyStrTT u1) (prettyStrTT u2)] in
  sugarArrow := true;
  match u1, u2 with
    | UVar(x), UVar(y) -> x = y
    | URef(x), URef(y) -> x = y
    | UArr(arr1), UArr(arr2) -> checkArrow errList usedBoxes g arr1 arr2
    | _ -> err (errList @ ["Syntactic types don't match up."])

and checkArrow errList usedBoxes g
      ((ts1,ls1,hs1),x1,t11,e11,t12,e12) ((ts2,ls2,hs2),x2,t21,e21,t22,e22) =

  checkLength "type" errList ts1 ts2;
  checkLength "loc" errList ls1 ls2;
  checkLength "heap" errList hs1 hs2;

  let (tSubst,lSubst,hSubst) =
    (List.combine ts1 (List.map (fun x -> ty (PUn(HasTyp(theV,UVar(x))))) ts2),
     List.combine ls1 (List.map (fun x -> LocVar x) ls2),
     List.combine hs1 (List.map (fun x -> ([x],[])) hs2)) in

  let subst = ([], tSubst, lSubst, hSubst) in
  let t11 = masterSubstTyp subst t11 in
  let e11 = masterSubstHeap subst e11 in

  (* TODO redo this, since not using worlds *)

  let errList' =
    errList @ [spr "input worlds:\n   %s\n / %s\n < %s\n / %s"
                 (prettyStrTyp t21) (prettyStrHeap e21)
                 (prettyStrTyp t11) (prettyStrHeap e11)]
  in
  let vSubst = checkWorlds errList' usedBoxes g (t21,e21) (t11,e11) in
  let vSubst = (x1, wVar x2)::vSubst in

  let subst = (vSubst, tSubst, lSubst, hSubst) in
  let t12 = masterSubstTyp subst t12 in
  let e12 = masterSubstHeap subst e12 in

  let errList' =
    errList @ [spr "output worlds:\n   %s\n / %s\n < %s\n / %s"
                 (prettyStrTyp t12) (prettyStrHeap e12)
                 (prettyStrTyp t22) (prettyStrHeap e22)]
  in
  Zzz.pushScope ();
  let (n,g) = simpleSnapshot "sub-arrow" g e21 in
  Zzz.pushBinding x2 (applyTyp t21 (wVar x2));
  ignore (checkWorlds errList' usedBoxes g (t12,e12) (t22,e22));
  Zzz.popBinding ();
  simpleTcRemoveBindingN n;
  Zzz.popScope ();

  true

and checkHeaps errList usedBoxes g h1 h2 =
  let errList =
    errList @ [spr "checkHeaps:\n  %s\n< %s"
                 (prettyStrHeap h1) (prettyStrHeap h2)] in
  if h1 = botHeap then botSubst
  else if h1 = h2 then []
  else begin

    (* check heap variables *)
    let ((hs1,cs1),(hs2,cs2)) = (h1, h2) in
    let (hs1,hs2) = (List.sort compare hs1, List.sort compare hs2) in
    if hs1 <> hs2 then
      err (errList @ [spr "heap variables not the same:\n   %s\n!= %s"
                      (String.concat "," hs1) (String.concat "," hs2)]);

    (* check location constraints *)
    let (binderSubst,obligations) = heapSubstAndObligations errList cs1 cs2 in
    Zzz.pushScope ();
    let (n,g) = simpleSnapshot "check-heaps" g h1 in
    List.iter (function 
      | OConc(x2,s2) ->
          let p = applyTyp s2 (wVar x2) in
          let p = masterSubstForm (binderSubst,[],[],[]) p in
          checkFormula errList usedBoxes g p
    ) obligations;
    simpleTcRemoveBindingN n;
    Zzz.popScope ();
    binderSubst
  end

and checkWorlds errList usedBoxes g (t1,h1) (t2,h2) =
  let errList = errList @ ["checkWorlds:"] in
  let subst = checkHeaps errList usedBoxes g h1 h2 in
  Zzz.pushScope ();
  let (n,g) = simpleSnapshot "check-worlds" g h1 in
  checkTypes errList usedBoxes g t1 (masterSubstTyp (subst,[],[],[]) t2);
  simpleTcRemoveBindingN n;
  Zzz.popScope ();
  subst


(***** Entry point ************************************************************)

let types cap  = checkTypes  [spr "Sub.types: %s" cap]  TypeTerms.empty
let heaps cap  = checkHeaps  [spr "Sub.heaps: %s" cap]  TypeTerms.empty
let worlds cap = checkWorlds [spr "Sub.worlds: %s" cap] TypeTerms.empty

let mustFlow   = mustFlow_ TypeTerms.empty
let canFlow    = canFlow_ TypeTerms.empty
