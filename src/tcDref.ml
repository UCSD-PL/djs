
open Lang
open LangUtils
open TcUtils


(**** Selfify *****************************************************************)

(* Rather than blindly returning {v=x}, check if the type of x is a syntactic
   type, and if so, keep that exposed at the top level so that don't need
   as many extractions. *)

let addPredicate p = function
  | PTru -> p
  | PConn("and",ps) -> pAnd (ps @ [p])
  | q -> pAnd [q;p]

let selfifyVar g x =
  try
    let eqX = eq theV (wVar x) in
    begin match List.find (function Var(y,_) -> x = y | _ -> false) g with
      | Var(_,THasTyp(us,p)) -> THasTyp (us, addPredicate eqX p)
      | _                    -> ty eqX
    end
  with Not_found ->
    err [spr "selfifyVar: var not found: [%s]" x]
  
let selfifyVal g = function
  | VVar(x) -> selfifyVar g x
  | v       -> ty (PEq (theV, WVal v))


(**** Environment operations **************************************************)

let removeLabels g =
  List.filter (function Lbl _ -> false | _ -> true) g

let printBinding (x,s) =
  if !Settings.printAllTypes || !depth = 0 then begin
    setPretty true;
    pr "\n%s :: %s\n" x (strTyp s);
    setPretty false;
    flush stdout;
    ()
  end


(* TODO should be factored somewhere, since Wf does something similar *)
let depTupleBinders t =
  let rec foo acc = function
    | TTuple(l) -> 
        let (xs,ts) = List.split l in
        let acc = List.fold_left (fun acc x -> x::acc) acc xs in
        List.fold_left foo acc ts
    | TNonNull(t) | TMaybeNull(t) -> foo acc t
    | _ -> acc
  in foo [] t


let addDepTupleBindings g t =
  let rec foo (accN,accG) = function
    | TTuple(l) ->
        List.fold_left (fun (accN,accG) (x,s) ->
          Zzz.addBinding ~isNew:true x PTru;
          (succ accN, Var(x,s) :: accG)
        ) (accN,accG) l
    | TNonNull(t) | TMaybeNull(t) -> foo (accN, accG) t
    | _ -> (accN, accG)
  in
  let rec bar = function
    | TTuple(l) ->
        List.iter (fun (x,s) ->
          Zzz.addBinding ~isNew:false x (applyTyp s (wVar x));
          printBinding (x,s);
        ) l
    | TNonNull(t) | TMaybeNull(t) -> bar t
    | _ -> ()
  in
(*
  let rec baz g = function
    | TTuple(l) -> List.iter (tryUnfold g) l
    | TNonNull(t) | TMaybeNull(t) -> baz g t
    | _ -> ()
  in
*)
  let (n,g) = foo (0,g) t in (* first, get all vars in scope *)
  bar t;                     (* second, assert all their types *)
(*
  baz g t;                   (* finally, try to do non-det unfold *)
*)
  (n, g)

(* TODO why does this need to take in h? just for printing? *)

let tcAddBinding ?(printHeap=true) ?(isNew=true) g h x s =

  let (n,g) = addDepTupleBindings g s in

  Zzz.addBinding ~isNew x (applyTyp s (wVar x));
  printBinding (x,s);
  let g = Var(x,s)::g in
(*
  let (g,h) = tryDestruct g h x s in (* unfolding with new env that x:s *)
*)
  (* unfolding with new env that has x:s *)
(*
  tryUnfold g (x,s);
*)
  if !Settings.printAllTypes || !depth = 0 then begin
    if printHeap
    then pr "/ %s\n" (prettyStr strHeap h)
    else ()
  end;
  (succ n, g)

(*
let tcRemoveBinding () =
  Zzz.removeBinding ();
  ()
*)

let tcAddTypeVar x g =
  Zzz.addTypeVar x;
  TVar(x)::g

let tcRemoveTypeVar () =
  Zzz.removeBinding ();
  ()

let tcRemoveBindingN n =
(*
  for i = 1 to n do tcRemoveBinding () done
*)
  for i = 1 to n do Zzz.removeBinding () done


(***** Heap operations ********************************************************)

(* TODO avoid snapshotting unchanged bindings more than once *)

let snapshot g h =
  let l = List.map snd (snd h) in
  let add = tcAddBinding ~printHeap:false in
  let (n,g1) = 
    List.fold_left (fun (k,acc) -> function
      | HWeakObj _ -> (k, acc)
      | HConc(x,t) | HConcObj(x,t,_) ->
          let (i,g) = add acc h x tyAny in
          (* TODO 11/27: doing this so all the dep tuple binders get declared. *)
          let ys = depTupleBinders t in
          List.fold_left
            (fun (k,acc) y -> let (j,g) = add acc h y tyAny in (k+j, g))
            (i,g) ys
    ) (0,g) l
  in
  let g2 = 
    List.fold_left (fun acc -> function
      | HWeakObj _ -> acc
      (* TODO: here's one obvious place where binders are getting redefined *)
      | HConc(x,s) | HConcObj(x,s,_) -> snd (add ~isNew:false acc h x s)
    ) g1 l
  in
  (n, g2)


let freshenWorld (t,(hs,cs)) =
(*
  let vSubst =
    List.map
      (function (_,HConc(x,_)) | (_,HConcObj(x,_,_)) -> (x, freshVar x)) cs in
*)
  let vSubst =
    List.rev (List.fold_left (fun acc -> function
      | (_,HConc(x,_))
      | (_,HConcObj(x,_,_)) -> (x, freshVar x) :: acc
      | (_,HWeakObj _) -> acc
    ) [] cs) in
  let subst = (List.map (fun (x,y) -> (x, wVar y)) vSubst, [], [], []) in
  let (fresh,cs) =
    List.fold_left (fun (acc1,acc2) -> function
      | (l,HConc(x,s)) ->
          let x' = List.assoc x vSubst in
          let s' = masterSubstTyp subst s in
          ((x',s')::acc1, (l,HConc(x',s'))::acc2)
      | (l,HConcObj(x,s,l')) ->
          let x' = List.assoc x vSubst in
          let s' = masterSubstTyp subst s in
          ((x',s')::acc1, (l,HConcObj(x',s',l'))::acc2)
      | (l,HWeakObj(thaw,s,l')) ->
          let s' = masterSubstTyp subst s in
          (acc1, (l,HWeakObj(thaw,s',l'))::acc2)
    ) ([],[]) cs in
  let t = masterSubstTyp subst t in
  (fresh, (t, (hs, cs)))

let selfifyHeap g (hs,cs) =
  let (fresh,cs) =
    List.fold_left (fun (acc1,acc2) -> function
      | (l,HConc(x,s)) ->
          let x' = freshVar x in
          (* ((x',s)::acc1, (l, HConc (x', ty (PEq (theV, wVar x))))::acc2) *)
          ((x',s)::acc1, (l, HConc (x', selfifyVar g x))::acc2)
      | (l,HConcObj(x,s,l')) ->
          let x' = freshVar x in
          (* ((x',s)::acc1, (l, HConcObj (x', ty (PEq (theV, wVar x)), l'))::acc2) *)
          ((x',s)::acc1, (l, HConcObj (x', selfifyVar g x, l'))::acc2)
      | (l,HWeakObj(thaw,s,l')) ->
          (acc1, (l, HWeakObj (thaw, s, l')) :: acc2)
    ) ([],[]) cs
  in
  (fresh, (hs, cs))

(* both findHeapCell functions look for the first matching constraint *)

let findHeapCell l (_,cs) =
  try Some (snd (List.find (fun (l',_) -> l = l') cs))
  with Not_found -> None

let findAndRemoveHeapCell l (hs,cs) =
  match findHeapCell l (hs,cs) with
    | Some(cell) -> Some (cell, (hs, List.remove_assoc l cs))
    | None       -> None

let splitHeapAround h l = failwith "splitHeapAround"
(*
let splitHeapAround h l =
  let rec foo prefix = function
    | []                      -> None
    | (l',hc)::tl when l = l' -> Some (prefix, hc, tl)
    | (l',hc)::tl             -> foo (prefix @ [l',hc]) tl
  in
  foo [] h
*)

let splitHeapForCall _ _ = failwith "splitHeapForCall"
(*
(* partitioning the heap h by walking in order, and selecting the elements
   that match the domain of h11 *)
let splitHeapForCall h h11 =
(*
  let dom = List.map fst h11 in
  let (h2,h1) = List.partition (fun (l,_) -> List.mem l dom) h in
  (h1, h2)
*)
  let (h1,h2) =
    List.fold_left (fun (h1,h2) hc ->
      let l = match hc with HAbs(l,_) | HConc(l,_,_) -> l in
      if List.mem l (Wf.domH h11)
        then (h1, hc::h2)
        else (hc::h1, h2)
    ) ([],[]) h
  in
  (List.rev h1, List.rev h2)
*)

let checkLocActuals _ _ _ = failwith "checkLocActuals"
(*
let checkLocActuals cap lf la =
  let err s = err (spr "%s: %s" cap s) in
  let (n,m) = List.length lf, List.length la in
  if n <> m then err (spr "got %d loc actuals but expected %d" m n)
  else match Utils.someDupe la with
    | Some(x) -> err (spr "[%s] duplicate" x)
    | None    -> List.combine lf la
*)


(***** Var elimination for let rules ******************************************)

(* stop checking heap well-formedness at the EHeap exp *)
let checkWfHeap = ref true

(* TODO 11/22 *)

let rec mkExists s = function
  | (x,t)::l -> TExists (x, t, mkExists s l)
  | []       -> s

let finishLet cap g y l (s,h) =
  (* TODO: 11/26 hack so that EHeap works w/o change
           2/27 also special casing djs_prelude *)
  if y = "end_of_pervasives" then checkWfHeap := false;
  if y = "end_of_djs_prelude" then checkWfHeap := false;

  if not !Settings.tryElimLocals then (s, h)
  else begin
(*
    if y = "begin_main" then checkWfHeap := false;
    let s = List.fold_left (fun acc (x,s1) -> elimLocalTyp x s1 acc) s l in
    let h = List.fold_left (fun acc (x,s1) -> elimLocalHeap x s1 acc) h l in
    if !checkWfHeap then Wf.world (spr "finishLet: %s" cap) g (s,h);
    (s, h)
*)
    let w = (mkExists s l, h) in
    (* alg typing should now synthesize only wf worlds b/c of existentials. 
       but doing this as a sanity check. *)
    if !checkWfHeap then Wf.world (spr "finishLet: %s" cap) g w;
    w
  end


(***** Misc operations ********************************************************)

(* TODO when adding abstract refs, revisit these two *)

let refTermsOf g = function
  | THasTyp([URef(l)],_) ->
      let _ = pr "don't call extract [Ref(%s)]\n" (strLoc l) in
      [URef l]
  | t ->
      let _ = pr "call extract refTermsOf [%s]\n" (prettyStrTyp t) in
      let isConcRef = function URef _ -> true | _ -> false in
      TypeTerms.elements (Sub.mustFlow g t ~filter:isConcRef)

let singleRefTermOf cap g t =
  match refTermsOf g t with
    | [URef(l)] -> l
    | []        -> err ([cap; "0 ref terms flow to value"])
    | l         -> err ([cap; "multiple ref terms flow to value";
                         String.concat ", " (List.map prettyStrTT l)])

let singleStrongRefTermOf cap g t =
  let l = singleRefTermOf cap g t in
  if isWeakLoc l
  then err [cap; spr "[%s] flows to value, but is not strong" (strLoc l)]
  else l

(*
let singleRefTermOf cap g = function
  | THasTyp(URef(l)) -> l
  | t -> begin
      pr "raviref %s\n" (strTyp t);
      match refTermsOf g t with
        | [URef(l)] -> l
        | []        -> err ([cap; "0 ref terms flow to value"])
        | l         -> err ([cap; "multiple ref terms flow to value";
                             String.concat ", " (List.map prettyStrTT l)])
    end
*)

let ensureSafeWeakRef cap g t =
  failwith "ensureSafeWeakRef"
(*
  let safe = TRefinement ("v", PNot (PEq (theV, aNull))) in
  Sub.checkTypes cap g TypeTerms.empty t safe
*)

let arrayTermsOf g = function
  | THasTyp([UArray(t)],_) ->
      let _ = pr "don't call extract [Array(%s)]\n" (strTyp t) in
      [UArray t]
  | t ->
      pr "call extract arrayTermsOf [%s]\n" (prettyStrTyp t);
      let filter = function UArray _ -> true | _ -> false in
      TypeTerms.elements (Sub.mustFlow g t ~filter)

let arrowTermsOf g t =
  match t with
    | THasTyp(us,_) ->
        (* this means that if there are any type terms at the top-level of
           the type, return them. not _also_ considering the refinement to
           see if that leads to more must flow boxes. *)
        let _ = pr "don't call extract EApp [%s]\n" (prettyStrTyp t) in
        us
    | _ ->
        let _ = pr "call extract EApp [%s]\n" (prettyStrTyp t) in
        let filter = function UArr _ -> true | _ -> false in
        TypeTerms.elements (Sub.mustFlow g t ~filter)


(***** TC helpers *************************************************************)

let oc_wrap_goal = open_out (Settings.out_dir ^ "wrap_goal.txt")

(* 9/27 switching this to world instead of annot *)
let wrapWithGoal cap x e w =
  failwith "wrapWithGoal"
(*
  let y = spr "wrapWithGoal_%s" x in
  fpr oc_wrap_goal "%s\n%s \nsGoal = %s\n\n" y cap (prettyStr strWorld w);
  EAs (y, e, w)
*)

(*
let strFrame (h1,(s2,h2)) =
  spr "    %s\n -> %s\n  / %s"
    (prettyStrHeap h1) (prettyStrScm s2) (prettyStrHeap h1)
*)

let applyFrame hAct (ls,h1,(t2,h2)) =
  match ls with
    | [x] when h1 = ([x],[]) && h1 = h2 -> (t2, hAct)
    | _ -> failwith "applyFrame: need to implement general case"

(*
let applyFrame g h (h11,(s,h12)) =
  failwith "applyFrame"
*)
(*
  let (h0,h1) = splitHeapForCall h h11 in
  let subst = niceCheckHeaps ["SHOULD PASS CAPS TO applyFrame"] g h1 h11 in
(*
  (* TODO freshen heap ? *)
  (h0, (applyVarSubstScm subst s, applyVarSubstHeap subst h12))
*)
  (* TODO 9/28 *)
  (h0, (applyVarSubstScm subst s, snd (freshen (applyVarSubstHeap subst h12))))
*)

(*
(* this won't be needed if just remove AScm eventually. then applyFrame
   can be used directly instead of applyAnnotation. *)
let applyAnnotation g h = function
  | AScm(s)   -> applyFrame g h ([],(s,[]))
  | AFrame(f) -> applyFrame g h f
*)


(***** TC lambda helpers ******************************************************)

let isArrow = function
  | TRefinement(x,PUn(HasTyp(y,UArr(arr)))) when y = wVar x -> Some arr
(*
  | THasTyp(UArr(arr)) -> Some arr
*)
  | THasTyp([UArr(arr)],PTru) -> Some arr
  | _ -> None

let isArrows t =
  match isArrow t, t with
    | Some(arr), _ -> Some [arr]
    | None, TRefinement(x,PConn("and",ps)) ->
        List.fold_left (fun acc p ->
          match acc, p with
            | Some(l), PUn(HasTyp(y,UArr(arr))) when y = wVar x -> Some(arr::l)
            | _ -> None
        ) (Some []) ps
    | _, THasTyp(us,PTru) ->
        List.fold_left (fun acc u ->
          match acc, u with
            | Some(l), UArr(arr) -> Some(arr::l)
            | _ -> None
        ) (Some []) us
    | _ -> None

type app_rule_result =
  | AppOk   of (vvar * typ) list * world
  | AppFail of string list

(* for each dep tuple binder x in t, adding a mapping from x to w.path,
   where path is the path to the x binder *)
let depTupleSubst t w =
  let rec foo path acc = function
    | TTuple(l) ->
        Utils.fold_left_i (fun acc (x,t) i ->
          let path = sel path (wProj i) in
          let acc = foo path acc t in
          (x, path) :: acc
        ) acc l
    | TNonNull(t) | TMaybeNull(t) -> failwith "depTupleSubst: null"
    | _ -> acc
  in
  let subst = foo w [] t in
  subst

let heapDepTupleSubst (_,cs) =
  let rec foo path acc = function
    | TTuple(l) ->
        Utils.fold_left_i (fun acc (x,t) i ->
          let path = sel path (wProj i) in
          let acc = foo path acc t in
          (x, path) :: acc
        ) acc l
    | TNonNull(t) | TMaybeNull(t) -> failwith "heapDepTupleSubst: null"
    | _ -> acc
  in
  let subst =
    List.fold_left (fun acc -> function
      | (_,HConc(x,s)) | (_,HConcObj(x,s,_)) -> foo (wVar x) acc s
      | _ -> acc (* TODO 3/9 *)
    ) [] cs
  in
(*
List.iter (fun (x,w) -> pr "ravi %s |-> %s\n" x (prettyStrWal w)) subst;
*)
  subst


(***** Heap parameter inference ***********************************************)

let oc_local_inf = open_out (Settings.out_dir ^ "local-inf.txt")

let inferHeapParam cap curHeap hActs hForms e11 =
  match hActs, hForms, e11 with

    | [], [x], _ when e11 = ([x],[]) -> Some curHeap

    (* more general than the previous case. the inferred heap arg is
       all of curHeap except the location constraint corresponding to
       the formal heap location constraints. *)
    | [], [x], ([x'],cs1) when x = x' ->
        let (hs,cs) = curHeap in
        Some (hs, List.filter (fun (l,_) -> not (List.mem_assoc l cs1)) cs)

    | _ -> None

(* TODO

    | [x], ([x'],_), ([x''],_) when x = x' && x = x'' ->
        err [cap;
             "ts eletapp: TODO heap instantiation";
             spr "hForms = %s" (String.concat "," hForms);
             spr "e11 = %s" (prettyStrHeap e11);
             spr "e12 = %s" (prettyStrHeap e12)]
    | _ ->
        let s = "[...; ...; H] x:T1 / [H ++ ...] -> T2 / [H ++ ...]" in
        err [cap; spr "arrow not of the form %s" s;
                  prettyStrHeap e11;
                  prettyStrHeap e12]
*)

let inferHeapParam x cap curHeap hActs hForm e11 =
  fpr oc_local_inf "\nlet [%s]\n" x;
  match inferHeapParam cap curHeap hActs hForm e11 with
    | None -> None
    | Some(e) -> begin
        fpr oc_local_inf "  heap formal: %s\n" (prettyStrHeap e11);
        fpr oc_local_inf "  inferred heap: %s\n " (prettyStrHeap e);
        Some e
      end


(***** Type/loc parameter inference *******************************************)

(** This is tailored to inferring location parameters and type variables for
    object and array primitive operations. Both the Ref and Array type term
    constructors are invariant in their parameter, so the greedy choice
    (e.g. unification) is guaranteed to be good.

    The entry point is

      inferTypLocParams g tForms lForms tForm hForm tActs lActs vAct hAct

 ** Step 1: Find type and value tuples

      Want to collect a tuple vTup of value arguments passed in, and a tuple tTup
      of type arguments expected, so that we can compare each vTup[i] to tTup[i]
      to infer missing arguments. There are three cases for function
      types/calls from desugaring:
                                    i.   direct call to a !D primitive
                                    ii.  DJS simple call
                                    iii. DJS method call

      Case i:    tForm = [x1:T1, ..., xn:Tn]

        The argument vAct must be a tuple with n values.

      Case ii:   tForm = [arguments:Ref(Largs)]

        The last location parameter is Largs. Look for Largs in the heap
        formal, and it should be a tuple of types tTup. The last (and only
        location) argument should be argsArray. Look for this location
        in the heap and use its value as the vTup.
 
      Case iii:  tForm = [this:Tthis, arguments:Targuments]

        Just like the previous case, but add Tthis to the front of the
        type tuple, and the this argument to the front of the value tuple.

 ** Step 2: Inferring location parameters for location formals lForms

      Process lForms in increasing order.

      For each Li:

      - if    there is some tTup[j] = Ref(Li)
        and   G => vTup[j] :: Ref(l)
        then  add Li |-> l to the location substitution

      - if    there is some (L |-> (_:_, Li)) in the heap formal
        and   L |-> l is part of location substitution
        and   (l |-> (_:_, l')) is in the heap actual
        then  add Li |-> l' to the location substitution

      Notice that for a function that takes a reference to L1, and the
      heap constraint for L1 links to L2, then the location parameter L1
      must appear in lForms before L2. This is how all the primitives
      are written anyway, since it's intuitive.

 ** Step 3: Inferring type parameters for type formals tForms

      For each Ai:

      - if    there is some Lj s.t. (Lj |-> (_:Arr(A), _))
        and   the location substitution maps Lj to l
        and   (l |-> (a:_, _)) is in the heap actual
        and   G => a :: Arr(T)
        then  add A |-> T to the type substitution

      Note that the first step looks for Arr(A) syntactically, which is
      how all the primitives are written. Might need to make this more
      general later.
*)

let _strTyps ts = String.concat "," (List.map strTyp ts)
let _strVals vs = String.concat "," (List.map prettyStrVal vs)

let isIntOfString s =
  try Some (int_of_string s) with Failure _ -> None

(* try to match v as a tuple dictionary, that is, a dictionary with
   fields "0" through "n" in order without any duplicates. *)
let isValueTuple v =
  let rec foo acc n = function
    | VEmpty -> Some acc (* no need to rev, since outermost starts with "n" *)
    | VExtend(v1,VBase(Str(sn)),v3) ->
        (match isIntOfString sn with
           | Some(n') when n = n' -> foo (v3::acc) (n-1) v1
           | None -> None)
    | _ -> None
  in
  match v with
    | VExtend(_,VBase(Str(sn)),_) ->
        (match isIntOfString sn with Some(n) -> foo [] n v | None -> None)
    | VEmpty -> Some []
    | _ -> None

let findActualFromRefValue g lVar tTup vTup =
  let rec foo i = function
(*
    | THasTyp(URef(LocVar(lVar'))) :: ts when lVar = lVar' ->
*)
    | THasTyp([URef(LocVar(lVar'))],_) :: ts when lVar = lVar' ->
        if i >= List.length vTup then None
        else
          let vi = List.nth vTup i in
(* TODO 3/10
          begin match refTermsOf g (ty (PEq (theV, WVal vi))) with
*)
          begin match refTermsOf g (selfifyVal g vi) with
            | [URef(lAct)] ->
                let _ = fpr oc_local_inf "  %s |-> %s\n" lVar (strLoc lAct) in
                Some lAct
            | _ -> foo (i+1) ts
          end
    | _ :: ts -> foo (i+1) ts
    | [] -> None
  in
  foo 0 tTup

let findActualFromProtoLink locSubst lVar hForm hAct =
  let rec foo = function
    | (LocVar lVar', HConcObj (_, _, LocVar x)) :: cs when lVar = x ->
        if not (List.mem_assoc lVar' locSubst) then foo cs
        else begin match List.assoc lVar' locSubst with
          | None -> None
          | Some(lAct') ->
              if not (List.mem_assoc lAct' (snd hAct)) then foo cs
              else begin match List.assoc lAct' (snd hAct) with
                | HConcObj(_,_,lAct) ->
                    let _ = fpr oc_local_inf "  %s |-> %s\n" lVar (strLoc lAct) in
                    Some lAct
                | _ -> None
              end
        end
    | _ :: cs -> foo cs
    | []      -> None
  in
  foo (snd hForm)

let findArrayActual g tVar locSubst hForm hAct =
  let rec foo = function
(*
    | (LocVar lVar, HConc (_, THasTyp (UArray (THasTyp (UVar x))))) :: cs
    | (LocVar lVar, HConcObj (_, THasTyp (UArray (THasTyp (UVar x))), _)) :: cs
*)
    | (LocVar lVar, HConc (_, THasTyp ([UArray (THasTyp ([UVar x], _))], _))) :: cs
    | (LocVar lVar, HConcObj (_, THasTyp ([UArray (THasTyp ([UVar x], _))], _), _)) :: cs
      when tVar = x ->
(*
        let _ = pr "ravi %s" (strHeap hForm) in
*)
        if not (List.mem_assoc lVar locSubst) then foo cs
        else begin match List.assoc lVar locSubst with
          | None -> foo cs
          | Some(lAct) ->
              if not (List.mem_assoc lAct (snd hAct)) then foo cs
              else begin match List.assoc lAct (snd hAct) with
                | HConc(a,_)
                | HConcObj(a,_,_) ->
(*
                    (match arrayTermsOf g (ty (PEq (theV, wVar a))) with
*)
                    (match arrayTermsOf g (selfifyVar g a) with
                       | [UArray(t)] -> Some t
                       | _           -> foo cs)
              end
        end
    | _ :: cs -> foo cs
(*
    | c :: cs -> let _ = pr "didn't match %s" (prettyStrHeap ([],[c])) in foo cs
*)
    | []      -> None
  in
  foo (snd hForm)

let steps2and3 g tForms lForms vFormTup hForm vActTup hAct =

  fpr oc_local_inf "  vFormTup: [%s]\n" (_strTyps (List.map snd vFormTup));
  fpr oc_local_inf "  vActTup:  [%s]\n" (_strVals vActTup);

  (* Step 2 *)
  let locSubst =
    List.fold_left (fun subst lVar ->
      let maybeActual = 
        match findActualFromRefValue g lVar (List.map snd vFormTup) vActTup with
          | None       -> findActualFromProtoLink subst lVar hForm hAct
          | Some(lact) -> Some lact in
      ((lVar,maybeActual)::subst)
    ) [] lForms in

  let lActsOpt =
    List.fold_left (fun acc (_,lActOpt) ->
      match acc, lActOpt with
        | Some(l), Some(lAct) -> Some (lAct::l)
        | _                   -> None
    ) (Some []) locSubst in

  begin match lActsOpt with
    | None -> ()
    | Some(lActs) ->
        fpr oc_local_inf "  inferred all loc acts: [%s]\n" (strLocs lActs)
  end;

  (* Step 3 *)
  let tActsOpt =
    match tForms with
      | []     -> Some []
      | [tVar] -> (match findArrayActual g tVar locSubst hForm hAct with
                     | Some(tAct) -> Some [tAct]
                     | None       -> None)
      | _      -> None (* generalize the case for one to all tparams *) in

  (* don't need to reverse lActs, since the two folds reversed it twice *)
  match tActsOpt, lActsOpt with
    | Some(l1), Some(l2) -> begin
        fpr oc_local_inf "  inferred all typ acts: [%s]\n" (_strTyps l1);
        Some (l1, l2)
      end
    | _ -> None

let inferTypLocParams x g tForms lForms tForm hForm tActs lActs vAct hAct =
  if List.length tActs <> 0 then None
  else begin
    fpr oc_local_inf "\nlet [%s]\n" x;
    match tForm with
      | TTuple([("arguments",t)]) -> begin
          match t, lActs with
(*
            | THasTyp(URef(lArgsForm)), [lArgsAct] ->
*)
            | THasTyp([URef(lArgsForm)],_), [lArgsAct] ->
                let (lForms,_) = Utils.longHeadShortTail lForms in
                if not (List.mem_assoc lArgsForm (snd hForm)) then None
                else if not (List.mem_assoc lArgsAct (snd hAct)) then None
                else begin match List.assoc lArgsAct (snd hAct),
                                 List.assoc lArgsForm (snd hForm) with
                  | HConc(_,TRefinement("v",PEq(WVal(VVar"v"),WVal(v)))),
                    HConc(_,TTuple(vFormTup)) -> begin
                      match isValueTuple v with
                        | None -> None
                        | Some(vActTup) -> begin
                            match steps2and3 g tForms lForms vFormTup hForm
                                             vActTup hAct with
                              | Some(ts,ls) -> Some (ts, ls @ [lArgsAct])
                              | None        -> None
                          end
                    end
                  | _ -> None
                end
            | _ -> None
        end
      (* copied from above case, and doing a bit extra to process the this
         formal and actual *)
      | TTuple([("this",tThis);("arguments",t)]) -> begin
          match t, lActs with
(*
            | THasTyp(URef(lArgsForm)), [lArgsAct] ->
*)
            | THasTyp([URef(lArgsForm)],_), [lArgsAct] ->
                let (lForms,_) = Utils.longHeadShortTail lForms in
                if not (List.mem_assoc lArgsForm (snd hForm)) then None
                else if not (List.mem_assoc lArgsAct (snd hAct)) then None
                else begin match List.assoc lArgsAct (snd hAct),
                                 List.assoc lArgsForm (snd hForm),
                                 isValueTuple vAct with
                  | HConc(_,TRefinement("v",PEq(WVal(VVar"v"),WVal(v)))),
                    HConc(_,TTuple(vFormTup)),
                    Some([vThis;_]) -> begin
                      match isValueTuple v with
                        | None -> None
                        | Some(vActTup) -> begin
                            let vFormTup = ("this",tThis) :: vFormTup in
                            let vActTup = vThis :: vActTup in
                            match steps2and3 g tForms lForms vFormTup hForm
                                             vActTup hAct with
                              | Some(ts,ls) -> Some (ts, ls @ [lArgsAct])
                              | None        -> None
                          end
                    end
                  | _ -> None
                end
            | _ -> None
        end
      | TTuple(vFormTup) -> begin
          match isValueTuple vAct with
            | None -> None
            | Some(vActTup) ->
                steps2and3 g tForms lForms vFormTup hForm vActTup hAct
        end
      | _ -> None
  end


(***** Bidirectional type checking ********************************************)

let initHeapSet = ref false

(***** Initial trivial checks *****)

let rec tsVal g h e =
  if Zzz.falseIsProvable "tsVal" then tyFls
  else tsVal_ g h e

and tsExp g h e =
  if Zzz.falseIsProvable "tsExp" then (tyFls, botHeap)
  else tsExp_ g h e

and tcVal g h s e =
  if Zzz.falseIsProvable "tcVal" then ()
  else tcVal_ g h s e

and tcExp g h w e =
  if Zzz.falseIsProvable "tcExp" then ()
  else tcExp_ g h w e


(***** Value type synthesis ***************************************************)

and tsVal_ g h = function

(* TODO add v::Null back in
  | VBase(Null) -> tyNull
*)

  | VVar("__skolem__") -> tyNum

  | (VBase _ as v) | (VEmpty as v) -> ty (PEq (theV, WVal v))

  (* TODO any benefit to using upd instead of VExtend? *)
  | (VExtend(v1,v2,v3) as v) -> begin
      tcVal g h tyDict v1;
      tcVal g h tyStr v2;
      ignore (tsVal g h v3);
      ty (PEq (theV, WVal v))
    end

(*
  | VVar(x) -> begin
      try
        let _ = List.find (function Var(y,_) -> x = y | _ -> false) g in
        ty (PEq (theV, wVar x))
      with Not_found ->
        err [spr "ts: var not found: [%s]" x]
    end
*)

  | VVar(x) -> selfifyVar g x

(*
  | VVar(x) -> begin
      try
        (match List.find (function Var(y,_) -> x = y | _ -> false) g with
           | Var(_,THasTyp(URef(l))) -> THasTyp (URef l)
           | Var _                   -> ty (PEq (theV, wVar x))
           | _                       -> failwith "TS-Var impossible")
      with Not_found ->
        err [spr "ts: var not found: [%s]" x]
    end
*)

  | VFun(l,x,Some(t1,h1),e) -> begin
      failwith "ts VFun"
(*
      let g = removeLabels g in
      (* TODO unfortunately duplicating some work of UArrImp, since
         don't want to check the synthesized return type here... *)
      Wf.wfLocFormalsFail "ts annotated VFun" l;
      Wf.wfHeapFail "ts annotated VFun: h1" g h1;
      Wf.wfTypFail "ts annotated VFun: t1" g h1 t1;
      Zzz.pushScope ();
      let (n,g) = snapshot g h1 in 
      let (g,h1) = tcAddBinding g h1 x (STyp t1) in
      let (t2,h2) =
        match tsExp g h1 e with
          | STyp(t2),h2 -> (t2, h2)
          | _           -> err "ts VFun: t2"
      in
      tcRemoveBinding ();
      tcRemoveBindingN n;
      Zzz.popScope ();
      let t = tyArrImp l x t1 h1 t2 h2 in
(*
      Wf.wfTypFail "VFunImp" g t;
*)
      STyp t
*)
    end

  | VFun(l,x,None,e) -> failwith "ts bare VFun"
      (* tsVal g h (VFun(l,x,Some(tyAny,[]),e)) *)

  | VArray(t,vs) -> begin
      List.iter (tcVal g h t) vs;
      let n = List.length vs in
(*
      ty (pAnd (
        hastyp theV (UArray t)
        :: packed theV :: PEq (arrlen theV, wInt n)
        :: Utils.map_i (fun vi i -> PEq (sel theV (wInt i), WVal vi)) vs))
*)
(* 3/12
*)
      let ps = 
        (* eq (tag theV) (wStr tagArray) :: *)
        packed theV :: PEq (arrlen theV, wInt n)
        :: Utils.map_i (fun vi i -> PEq (sel theV (wInt i), WVal vi)) vs in
      THasTyp ([UArray t], pAnd ps)
    end


(***** Expression type synthesis **********************************************)

and tsExp_ g h = function

  | EVal(v) -> (tsVal g h v, h)

  | ELet(x,None,ENewref(l,EVal(v)),e) -> begin
      let ruleName = "TS-LetNewref" in
      let strE =
        spr "  let %s = ref %s (%s) in ..." x (strLoc l) (prettyStrVal v) in
      match findHeapCell l h with
        | Some(HConc _)
        | Some(HConcObj _) ->
            err ([spr "%s-Strong: %s" ruleName strE;
                  spr "location [%s] already bound" (strLoc l)])
        | None -> begin
            (* TODO should also check dead locations *)
            let s0 = tsVal g h v in
            let y = freshVar "hc" in
            let h1 = (fst h, snd h @ [(l, HConc (y, s0))]) in
            let s1 = tyRef l in
            let (n,g) = tcAddBinding g h1 y s0 in
            let (m,g) = tcAddBinding g h1 x s1 in
            let (s2,h2) = tsExp g h1 e in
(*
            tcRemoveBinding ();
            tcRemoveBinding ();
*)
            tcRemoveBindingN (n + m);
            let cap = spr "%s-Strong: %s" ruleName strE in
            finishLet cap g x [(y,s0);(x,s1)] (s2,h2)
          end
(*
      let ruleName = "TS-LetNewref" in
      let strE = spr "  let %s = ref %s (%s) in ..." x l (prettyStrVal v) in
      let err s = niceError [ruleName; strE; s] in
      match findHeapCell l h with
      | Some(HConc _) ->
          err (spr "concrete location [%s] already bound" l)
      | Some(HAbs(_,s)) -> begin
          tcVal g h s v;
          let sRef = STyp (tyIsBang theV (URef(l))) in
          let (g,h) = tcAddBinding g h x sRef in
          let (s2,h2) = tsExp g h e in
          tcRemoveBinding ();
          finishLet [ruleName ^ "-Weak"; strE] g x [(x,sRef)] (s2,h2)
        end
      | None -> begin
          (* TODO should also check dead locations *)
          (* TODO might also want a way to create as abstract, with
               weaker invariant *)
          let s0 = tsVal g h v in
          let y = freshVar "hc" in
          let h1 = h @ [HConc (l, y, s0)] in
          let s1 = STyp (tyIsBang theV (URef(l))) in
          let (g,h1) = tcAddBinding g h1 y s0 in
          let (g,h1) = tcAddBinding g h1 x s1 in
          let (s2,h2) = tsExp g h1 e in
          tcRemoveBinding ();
          finishLet [ruleName ^ "-Strong"; strE] g x [(y,s0);(x,s1)] (s2,h2)
        end
*)
    end

  | EDeref(EVal(v)) -> begin
      let cap = spr "TS-Deref: !(%s)" (prettyStrVal v) in
      let t1 = tsVal g h v in
      let l = singleRefTermOf cap g t1 in
      match findHeapCell l h with
(* TODO 3/10
        | Some(HConc(y,s)) -> (ty (PEq (theV, wVar y)), h)
*)
        | Some(HConc(y,s)) -> (selfifyVar g y, h)
        | Some(HConcObj _) -> err ([cap; "not handling ConcObj cell"])
        | None -> err ([cap; spr "unbound loc [%s]" (strLoc l)])
                     
(*
      let ruleName = "TS-Deref" in
      let strE = spr "  !(%s) " (prettyStrVal v) in
      let err s = niceError [ruleName; strE; s] in
      match tsVal g h v with STyp(t1) -> begin
        match refTermsOf g t1 with [URef(l)] -> begin
          match findHeapCell l h with
            | Some(HConc(_,y,s)) -> (selfify y s, h)
            | Some(HAbs(_,s))    -> (ensureSafeWeakRef "ts EDeref" g t1; (s, h))
            | None               -> err (spr "unbound loc [%s]" l)
        end
        | _ -> err (spr "[%s] should have exactly 1 ref term" (strValue v))
      end
      | _ -> err "should be a monotype"
*)
    end

  | ELet(x,None,ESetref(EVal(v1),EVal(v2)),e) -> begin
      let (s1,s2) = (prettyStrVal v1, prettyStrVal v2) in
      let cap = spr "TS-LetSetref: let %s = (%s) := (%s)" x s1 s2 in
      let t1 = tsVal g h v1 in
      let s2 = tsVal g h v2 in
      let l = singleRefTermOf cap g t1 in
      match findAndRemoveHeapCell l h with
        | None -> err ([cap; spr "unbound loc [%s]" (strLoc l)])
        | Some(HConcObj _, _) -> err ([cap; "not handling ConcObj cell"])
        | Some(HConc(y,s), (hs,cs)) -> begin
            Wf.heap cap g (hs,cs);
            let y2 = freshVar y in
            let h1 = (hs, cs @ [(l, HConc (y2, s2))]) in
            let (n,g) = tcAddBinding ~printHeap:false g h1 y2 s2 in
            let (m,g) = tcAddBinding g h1 x s2 in
            let (s3,h3) = tsExp g h1 e in
(*
            tcRemoveBinding ();
            tcRemoveBinding ();
*)
            tcRemoveBindingN (n + m);
            finishLet cap g x [(y2,s2);(x,s2)] (s3,h3)
          end
(*
      let ruleName = "TS-LetSetref" in
      let strE = spr "  let %s = (%s) := (%s) in ..."
                    x (prettyStrVal v1) (prettyStrVal v2) in
      let err s = niceError [ruleName; strE; s] in
      match tsVal g h v1 with STyp(t1) -> begin
        match refTermsOf g t1 with [URef(l)] -> begin
          match findAndRemoveHeapCell l h with
          | Some(HConc(_,y,s)),h0 -> begin
              let h00 = h0 @ [HAbs (l, STyp tyAny)] in
              Wf.wfHeapFail (spr "ts ELetSetref strong [%s]: h00" x) g h00;
              let s' = tsVal g h v2 in
              let y' = freshVar y in
              let h1 = h0 @ [HConc (l, y', s')] in
              let (g,h1) = tcAddBinding ~printHeap:false g h1 y' s' in
              let (g,h1) = tcAddBinding g h1 x s' in
              let (s2,h2) = tsExp g h1 e in
              tcRemoveBinding ();
              finishLet [ruleName; strE] g x [(y',s');(x,s')] (s2,h2)
            end
          | Some(HAbs(_,s)),_ -> begin
              ensureSafeWeakRef (spr "ts LetSetref [%s]" x) g t1;
              tcVal g h s v2;
              let (g,h) = tcAddBinding g h x s in
              let (s3,h3) = tsExp g h e in
              tcRemoveBinding ();
              finishLet [ruleName; strE] g x [(x,s)] (s3,h3)
            end
          | None,_ -> err (spr "unbound loc [%s]" l)
        end
        | _ -> err "should have exactly 1 conc ref term"
      end
      | _ -> err "should be a monotype"
*)
    end

  | ELet(x,None,EApp(l,EVal(v1),EVal(v2)),e) -> begin
      let t1 = tsVal g h v1 in
(*
      let filter = function UArr _ -> true | _ -> false in
      let _ = pr "call extract EApp [%s]\n" (prettyStrTyp t1) in
      let boxes = TypeTerms.elements (Sub.mustFlow g t1 ~filter) in
*)
      let boxes = arrowTermsOf g t1 in
      let (s1,s2) = (prettyStrVal v1, prettyStrVal v2) in
      let cap = spr "TS-LetApp: let %s = [...] (%s) (%s)" x s1 s2 in
      tsELetAppTryBoxes cap g h x l v1 v2 e boxes
(*
      let ruleName = "TS-LetApp" in
      let strE = spr "  let %s = (%s) <%s> (%s) in ..." x
        (prettyStrVal v1) (strLocs la) (prettyStrVal v2) in
      match tsVal g h v1 with
        | STyp(t1) ->
            let boxes = Sub.mustFlow g t1 TypeTerms.empty in
            let boxes = TypeTerms.elements boxes in
            tsELetAppTryBoxes strE g h x (v1,la,v2) e boxes
        | SAll _ ->
            niceError [ruleName; strE; "func has poly type"]
*)
    end

  | ELet(x,Some(f),EApp(l,EVal(v1),EVal(v2)),e) -> begin
      failwith "todo ts letapp with ann"
    end

(*
  | EFreeze(l,so) -> begin
      let cap = spr "ts EFreeze [%s] " l in
      let err s = err (spr "%s: %s" cap s) in
      match findAndRemoveHeapCell l h with
        | None,_ -> err "location not found"
        | Some(HAbs _),_ -> err "location is already non-linear"
        | Some(HConc(_,_,s')),h1 -> begin
            Wf.wfHeapFail cap g h1;
            let s =
              match so with
                | None    -> s'
                | Some(s) -> let _ = Sub.checkSchemes cap g s' s in s
            in
            let h' = h1 @ [HAbs (l, s)] in
            (STyp tyAny, h')
          end
    end
*)

  | ELet(x,None,ENewObj(EVal(v1),l1,EVal(v),l2),e) -> begin
      let cap = spr "TS-LetNewObj: new %s %s" (strLoc l1) (strLoc l2) in
      match findHeapCell l1 h, findHeapCell l2 h with
        | Some _, _ -> err [cap; spr "loc [%s] already bound" (strLoc l1)]
        | None, Some(HConcObj _) -> begin
            tcVal g h (tyRef l2) v;
            let y = freshVar "newobj" in
            (* let t = ty (PEq (theV, WVal VEmpty)) in *)
            let t = tsVal g h v1 in
            let s = tyRef l1 in
            let h1 = (fst h, snd h @ [l1, HConcObj (y, t, l2)]) in
            let (n,g) = tcAddBinding ~printHeap:false g h1 y t in
            let (m,g) = tcAddBinding g h1 x s in
            let (s2,h2) = tsExp g h1 e in
(*
            tcRemoveBinding ();
            tcRemoveBinding ();
*)
            tcRemoveBindingN (n + m);
            finishLet cap g x [(y,t);(x,s)] (s2,h2)
          end
        | None, Some _ -> err [cap; spr "loc [%s] isn't a conc obj" (strLoc l2)]
        | None, None -> err [cap; spr "loc [%s] isn't bound" (strLoc l2)]
    end

  (* TODO 11/29: should just move to using existentials everywhere instead
     of the specialized let rules.
     tweaking ANF to not introduce as many let bindings, so trying to cope
     with the typing rules that require binding forms... *)
(*
  | ELet(x,None,e1,EVal(VVar(x'))) when x = x' ->
      let (t1,h1) = tsExp g h e1 in
      (TExists (x, t1, ty (PEq (theV, wVar x))), h1)
*)

  (***** all typing rules that use special let-bindings should be above *****)

  | ELet(x,Some(a),e1,e2) -> begin
      let ruleName = "TS-Let-Ann" in
      Wf.frame (spr "%s: let %s = ..." ruleName x) g a;
      Zzz.pushScope ();
      let (s1,h1) = applyFrame h a in
      tcExp g h (s1,h1) e1;
      Zzz.popScope ();
      let (n,g1) = tcAddBinding g h1 x s1 in
      let (s2,h2) = tsExp g1 h1 e2 in
(*
      tcRemoveBinding ();
*)
      tcRemoveBindingN n;
      finishLet (spr "%s: let %s = ..." ruleName x) g x [(x,s1)] (s2,h2)
(*
      let ruleName = "TS-Let" in
      let strE = spr "  let %s :: ... = ..." x in
      let (h0,(s1,h1)) = applyAnnotation g h a in
      tcExp g h (s1,h1) e1;
      (* TODO check annotation a *)
      Wf.wfScmFail (spr "ts ann ELet [%s] annotation" x) g h s1;
      let h1 = h0 @ h1 in
      let (g,h1) = tcAddBinding g h1 x s1 in
      (* 9/23 added snapshot
         TODO might want to add bindings to the env without pushing their
         types, since they're already there? *)
      let (n,g) = snapshot g h1 in
      let (s2,h2) = tsExp g h1 e2 in
      tcRemoveBindingN n;
      tcRemoveBinding ();
      finishLet [ruleName; strE] g x [(x,s1)] (s2,h2)
*)
    end

  | ELet(x,None,e1,e2) -> begin
      let ruleName = "TS-Let-Bare" in
      Zzz.pushScope ();
      let (s1,h1) = tsExp g h e1 in
      Zzz.popScope ();
      let (n,g1) = tcAddBinding g h1 x s1 in
      let (s2,h2) = tsExp g1 h1 e2 in
(*
      tcRemoveBinding ();
*)
      tcRemoveBindingN n;
      finishLet (spr "%s: let %s = ..." ruleName x) g x [(x,s1)] (s2,h2)
(*
      let ruleName = "TS-Let-Bare" in
      let (s1,h1) = tsExp g h e1 in
      let (g,h1) = tcAddBinding g h1 x s1 in
      (* 9/23 added snapshot
         TODO might want to add bindings to the env without pushing their
         types, since they're already there? *)
      let (n,g) = snapshot g h1 in
      let (s2,h2) = tsExp g h1 e2 in
      tcRemoveBindingN n;
      tcRemoveBinding ();
      finishLet [ruleName; spr "  let %s = ..." x] g x [(x,s1)] (s2,h2)
*)
    end

  | EIf(EVal(v),e1,e2) -> begin 
      (* tcVal g h tyBool v; *)
      tcVal g h tyAny v;
      (* Zzz.pushForm (pGuard v true); *)
      Zzz.pushForm (pTruthy (WVal v));
      let (s1,h1) = tsExp g h e1 in (* same g, since no new bindings *)
      Zzz.popForm ();
      (* Zzz.pushForm (pGuard v false); *)
      Zzz.pushForm (pFalsy (WVal v));
      let (s2,h2) = tsExp g h e2 in (* same g, since no new bindings *)
      Zzz.popForm ();
      (* TODO better join for heaps *)
      let h12 = Sub.simpleHeapJoin v h1 h2 in
      let x = freshVar "_ret_if" in
      let p =
        pAnd [pImp (pGuard v true) (applyTyp s1 (wVar x));
              pImp (pGuard v false) (applyTyp s2 (wVar x))]
      in
(*
      (TRefinement(x,p), h12)
*)
      (* TODO 3/7 the heaps in the if happen inside a nested scope, so after
         the heap join, need a way to bring the binders in scope. this is
         really messy, but for now simply snapshotting those bindings by
         using exists *)
      let t = TRefinement(x,p) in
      let heapbindings =
        List.map
          (function (_,HConc(y,t)) | (_,HConcObj(y,t,_)) -> (y,t)) (snd h12) in
      (mkExists t heapbindings, h12)
    end

  | EExtern(x,s,e) -> begin
      if !depth > 0 then err [spr "extern [%s] not at top-level" x];
      let s = ParseUtils.undoIntersectionHack g s in
      Wf.typ (spr "ts extern %s" x) g h s;
      let (n,g) = tcAddBinding g h x s in
      let s2 = tsExp g h e in
(*
      tcRemoveBinding ();
*)
      tcRemoveBindingN n;
      s2
    end

(*
  | EHeap(h,e) -> begin
      if !depth <> 0  then failwith "ts EHeap: should be at top-level";
      if !initHeapSet then failwith "ts EHeap: init heap already set!";
      Wf.heap "EHeap: initial heap" g h;
      initHeapSet := true;
      let (n,g) = snapshot g h in 
      let (s,h') = tsExp g h e in
      tcRemoveBindingN n;
      (s, h')
    end
*)

  (* 3/9 *)
  | EHeap(h1,e) -> begin
      match h1 with
        | ([], [(l,HWeakObj(Frzn,t,l'))]) -> begin
            Wf.heap "EHeap: weak heap" g h1;
            let h' = (fst h, (l,HWeakObj(Frzn,t,l')) :: snd h) in
            let (s,h'') = tsExp g h' e in
            (s, h'')
          end
        | _ -> err ["TS-EHeap: should be a single frozen weak constraint"]
    end

  | ETcFail(s,e) ->
      failwith "ts tcfail"
(*
      let fail =
        try let _ = tsExp g h e in false
        with Tc_error _ -> true in
      if fail
        then (STyp tyAny, h)
        else err (spr "ts ETcFail: [\"%s\"] should have failed" s)
*)

  | EAs(s,e,f) -> begin
      let w = applyFrame h f in
      tcExp g h w (EAsW(s,e,w));
      w
    end

  | EAsW(s,e,w) -> begin
      Wf.world (spr "TS-EAsW: %s" s) g w;
      tcExp g h w e;
      w
    end

  | ELabel(x,ao,e) -> begin
      failwith "ts elabel"
(*
      let ruleName = "TS-Label" in
      let strE = spr "  #%s { ... }" x in
      Zzz.pushScope ();
      let a =
        match ao with
          | None -> failwith "TS-Label no annotation"
          | Some(a) -> a in
      let (h0,(s1,h1)) = applyAnnotation g h a in
      let w = tsExp (Label(x,Some(s1,h1))::g) h e in
      Zzz.popScope ();
      niceCheckWorlds [ruleName; strE] g w (s1,h1);
      (s1, h0 @ h1)
      (* TODO make sure this case is okay *)
*)
    end

  (* TODO 9/25 revisit *)
  | EBreak(x,EVal(v)) -> begin
      let cap = spr "TS-Break: break %s (%s)" x (prettyStrVal v) in
      let lblBinding =
        try List.find (function Lbl(y,_) -> x = y | _ -> false) g
        with Not_found -> err [cap; "label not found"]
      in
      match lblBinding with
        | Lbl(_,Some(tGoal,hGoal)) -> begin
            tcVal g h tGoal v;
            ignore (Sub.heaps cap g h hGoal);
            (tyFls, botHeap)
          end
        | _ -> err [cap; "no goal for label"]
(*
      let ruleName = "TS-Break" in
      let strE = spr "  break %s (%s)" x (prettyStrVal v) in
      let (s1,h1) =
        match lookupLabel x g with
          | Some(Some(w)) -> w
          | Some(None)    -> niceError [ruleName; strE; "env has no world"]
          | None          -> niceError [ruleName; strE; "label not found"]
      in
      tcVal g h s1 v;
      ignore (niceCheckHeaps ["TS-Break"; strE] g h h1);
      (STyp tyFls, botHeap)
*)
    end

  | EFreeze(m,EVal(v)) -> begin
      let cap = spr "ts EFreeze [%s] [%s]" (strLoc m) (prettyStrVal v) in
      if not (isWeakLoc m) then err [cap; "doesn't start with tilde"];
      match findAndRemoveHeapCell m h with
        | Some(HWeakObj(Frzn,t,l'), h0) -> begin
            let s = tsVal g h v in
            let l = singleStrongRefTermOf "ts EFreeze" g s in
            begin match findAndRemoveHeapCell l h0 with
              | Some(HConcObj(x,s,l''), h1) -> begin
                  if l' <> l'' then
                    err [cap; spr "[%s] wrong proto link" (strLoc l)];
                  Wf.heap cap g h1;
                  Sub.types cap g s t;
                  let h' = (fst h1, (m,HWeakObj(Frzn,t,l')) :: snd h1) in
                  (tySafeRef m, h')
                end
              | Some _ ->
                  err [cap; spr "[%s] isn't a strong obj" (strLoc l)]
              | None ->
                  err [cap; spr "[%s] not bound" (strLoc l)]
            end
          end
        | Some(HWeakObj(_,t,l'), _) ->
            err [spr "ts EFreeze: [%s] isn't frozen" (strLoc m)]
        | Some _ ->
            err [spr "ts EFreeze: [%s] isn't weak" (strLoc m)]
        | None ->
            err [spr "ts EFreeze: [%s] isn't bound in the heap" (strLoc m)]
    end

  | EThaw(l,EVal(v)) -> failwith "EThaw"

  | ERefreeze(l,EVal(v)) -> failwith "ERefreeze"

  | EThrow(EVal(v)) ->
      let _ = tsVal g h v in (tyFls, h)

  | ETryCatch _ -> failwith "ETryCatch"

  | ETryFinally _ -> failwith "ETryFinally"

  | ENewObj _ -> failwith "ts ENewObj: should've been typed with a let binding"

  | ELoadedSrc(_,e) -> tsExp g h e
  | ELoadSrc(s,_) ->
      failwith (spr "ts ELoadSrc [%s]: should've been expanded" s)

  (* the remaining cases should not make it to type checking, so they indicate
     some failure of parsing or ANFing *)

  | EBase _    -> Anf.badAnf "ts EBase"
  | EVar _     -> Anf.badAnf "ts EVar"
  | EDict _    -> Anf.badAnf "ts EDict"
  | EFun _     -> Anf.badAnf "ts EFun"
  | EIf _      -> Anf.badAnf "ts EIf"
  | EApp _     -> Anf.badAnf "ts EApp"
  | ENewref _  -> Anf.badAnf "ts ENewref"
(* TODO 11/29: falling back on special rule
  | ENewref(l,EVal(v)) ->
      let x = freshVar "dummylet" in
      tsExp g h (ELet(x,None,ENewref(l,EVal(v)),eVar x))
*)
  | EDeref _   -> Anf.badAnf "ts EDeref"
  | ESetref _  -> Anf.badAnf "ts ESetref"
  | EBreak _   -> Anf.badAnf "ts EBreak"
  | EThrow _   -> Anf.badAnf "ts EThrow"
  | EFreeze _  -> Anf.badAnf "ts EFreeze"
  | EThaw _    -> Anf.badAnf "ts EThaw"
  | ERefreeze _  -> Anf.badAnf "ts ERefreeze"

and tsELetAppTryBoxes cap g curHeap x (tActs,lActs,hActs) v1 v2 e boxes =

  let checkLength s l1 l2 s2 =
    let (n1,n2) = (List.length l1, List.length l2) in
    if n1 <> n2 then
      err [cap; spr "expected %d %s args but got %d %s" n1 s n2 s2] in

  let tryOne ((tForms,lForms,hForms),y,t11,e11,t12,e12) =

    let (tActs0,lActs0) = (tActs, lActs) in

    let ((tActs,lActs),sInf) =
      match inferTypLocParams x g tForms lForms t11 e11
                              tActs0 lActs0 v2 curHeap with
        | Some(ts,ls) -> ((ts, ls), "with help from local inference")
        | None        -> ((tActs0, lActs0), "without help from local inference") in

    (* TODO at some point, might want to rewrite the input program with
       inferred instantiations *)
    if (tActs,lActs) <> (tActs0,lActs0) then begin
      let foo (ts,ls) =
        spr "[%s; %s]" (String.concat "," (List.map strTyp ts))
                       (String.concat "," (List.map strLoc ls)) in
      pr "local inference succeeded:\n";
      pr "  before : %s\n" (foo (tActs0,lActs0));
      pr "  after  : %s\n" (foo (tActs,lActs));
    end;

    (* check well-formedness of all poly args *)
    checkLength "type" tForms tActs sInf;
    checkLength "loc" lForms lActs sInf;
    (match Utils.someDupe lActs with
       | None    -> ()
       | Some(l) -> err [cap; spr "duplicate loc arg: %s" (strLoc l)]
    );
    let tSubst = List.combine tForms tActs in
    let lSubst = List.combine lForms lActs in

    (* instantiate input world with poly args *)
    let (t11,e11) =
      (masterSubstTyp ([],tSubst,lSubst,[]) t11,
       masterSubstHeap ([],tSubst,lSubst,[]) e11) in

    (* infer missing poly arg.
       note: this must take place after loc args have been substituted. *)
    let hActs =
      match inferHeapParam x cap curHeap hActs hForms e11 with
        | Some(e) -> [e]
        | None    -> hActs in

    (* TODO: hInst should really keep track of polarity. but for
       simplicity, just substituting the actual actual for all
       occurrences in the input heap, and substituting the selfified
       actual for all occurrences in the output heap *)

    checkLength "heap" hForms hActs;
    let hSubst = List.combine hForms hActs in

    (* instantiate input world with rest of poly args.
       expand from pre-formulas to formulas. check that the result is wf *)
    let (t11,e11) =
      (masterSubstTyp ([],[],[],hSubst) t11,
       masterSubstHeap ([],[],[],hSubst) e11) in
    let (t11,e11) =
      (expandPreTyp t11, expandPreHeap e11) in

(*
    Wf.heap "e11 after instantiation" g e11;
    let vSubst = Sub.heaps cap g curHeap e11 in
    let t11 = masterSubstTyp (vSubst,[],[],[]) t11 in
    tcVal g curHeap t11 v2;
*)
    let argSubst = (y, WVal v2) :: (depTupleSubst t11 (WVal v2)) in
    let e11 = masterSubstHeap (argSubst,[],[],[]) e11 in

    (* TODO 11/30: moved heapPreSubst here, since it also needs to be
       applied to input heap *)
    let heapPreSubst = (heapDepTupleSubst e11,[],[],[]) in
    let e11 = masterSubstHeap heapPreSubst e11 in

    Wf.heap "e11 after instantiation" g e11;
    let heapSubst = Sub.heaps cap g curHeap e11 in
    tcVal g curHeap t11 v2;

    (* TODO: see the note about hInst above *)

    let (freshFromHInst,hAct) =
      match hActs with
        | [e] -> selfifyHeap g e
        | []  -> ([], ([],[]))
        | _   -> failwith "app: >1 heap arg nyi"
    in
    let hSubst = List.combine hForms [hAct] in

    let (nFromHInst,g) =
      List.fold_left (fun (n,g) (x,t) ->
        (* TODO is e11 the right one to pass in? *)
        let (m,g) = tcAddBinding g e11 x t in
        (n+m, g)
      ) (0,g) freshFromHInst in

    (* instantiate output world with poly args and binder substitution *)
    let polySubst = ([],tSubst,lSubst,hSubst) in
(*
    let heapPreSubst = (heapDepTupleSubst e11,[],[],[]) in
*)
    let valueSubst = (argSubst @ heapSubst,[],[],[]) in
(*
    let (fresh,(t12,e12)) =
      freshenWorld (t12,e12) in
*)
    let (t12,e12) =
      (masterSubstTyp polySubst t12, masterSubstHeap polySubst e12) in
    let (t12,e12) =
      (masterSubstTyp heapPreSubst t12, masterSubstHeap heapPreSubst e12) in
    let (t12,e12) =
      (masterSubstTyp valueSubst t12, masterSubstHeap valueSubst e12) in
    (* need to freshen after the argument heap binders have been substituted
       into return world *)
    let (fresh,(t12,e12)) =
      freshenWorld (t12,e12) in
    let (t12,e12) =
      (expandPreTyp t12, expandPreHeap e12) in
    Wf.heap "e12 after instantiation" g e12;

(*
    (* TODO 3/9 *)
    (match t12 with
       | THasTyp(UArr _) ->
           (pr "ravi yes %s\n" (prettyStrTyp t12); incr synCount)
       | _ ->
           (pr "ravi no %s\n" (prettyStrTyp t12); incr notSynCount));
*)

    (* now that call has been checked, process the let body *)
    let (n,g') = snapshot g e12 in
    let (m,g') = tcAddBinding g' e12 x t12 in
    let outWorld = tsExp g' e12 e in
(*
    tcRemoveBinding ();
    tcRemoveBindingN n;
*)
    tcRemoveBindingN (n + m);
    tcRemoveBindingN nFromHInst;
(*
    AppOk (fresh @ [(x,t12)], outWorld)
*)
    AppOk (freshFromHInst @ fresh @ [(x,t12)], outWorld)
  in
(*
  let ruleName = "TS-LetApp" in
  let tryOne (lf,y,t11,h11,t12,h12) =
    let subst = checkLocActuals ruleName lf la in
    let t11' = applyLocSubstTyp subst t11 in
    let t12' = applyLocSubstTyp subst t12 in
    let h11' = applyLocSubstHeap subst h11 in
    let h12' = applyLocSubstHeap subst h12 in
    let (h1,h2) = splitHeapForCall h h11' in
    Wf.wfHeapFail (spr "%s: split h1" ruleName) g h1;
    Wf.wfHeapFail (spr "%s: split h2" ruleName) g h2;
    let subst = Sub.checkHeapsFail ruleName g h2 h11' in
    (* tcVal g h (STyp (applyVarSubstTyp subst t11')) v2; *)
    tcVal g h2 (STyp (applyVarSubstTyp subst t11')) v2;
    let t = substTyp (AVal v2) (aVar y) (applyVarSubstTyp subst t12') in
    let (fresh,h2') = freshen (applyVarSubstHeap subst h12') in
    let h' = h1 @ h2' in
    let (n,g) = snapshot g h2' in
    let (g,h') = tcAddBinding g h' x (STyp t) in
    let (s3,h3) = tsExp g h' e in
    tcRemoveBinding ();
    tcRemoveBindingN n;
    AppOk (fresh @ [(x,STyp t)], (s3, h3))
  in
*)
  let result =
    (* use the first arrow that type checks the call *)
    Utils.fold_left_i (fun acc u i ->
      let s = prettyStrTT u in
      match acc, u with
        | AppOk _, _ -> acc
        | AppFail(l), UArr(uarr) -> begin
            try tryOne uarr
            with Tc_error(errList) ->
              AppFail (l @ [spr "\n*** box %d: %s" i s] @ errList)
          end
        | AppFail(l), _ -> AppFail (l @ [spr "box %d isn't an arrow: %s" i s])
    ) (AppFail []) boxes
  in
  match result with
    | AppOk(toElim,world) -> finishLet cap g x toElim world
    | AppFail(errors) ->
        let n = List.length boxes in
        let s = spr "%d boxes but none type check the call" n in
        printTcErr (cap :: s :: errors)
        (* the buck stops here, instead of raising Tc_error, since otherwise
           get lots of cascading let-bindings *)

(*
    | AppFail(errors) -> begin
        try (* one last shot at checking the call. if none of the boxes
               succeeded, try the special syntactic rule for array ops. *)
          tsELetAppArrayOperation g curHeap x (tActs,lActs,hActs) v1 v2 e
        with Tc_error(errors') ->
          let n = List.length boxes in
          let s = spr "%d boxes but none type check the call" n in
          let s' = "\n*** Also tried TS-GetElem, but that didn't work\n" in
          printTcErr (cap :: s :: errors @ [s'] @ errors')
          (* the buck stops here, instead of raising Tc_error, since otherwise
             get lots of cascading let-bindings *)
      end
*)

(*
(* the error messages from the previous tryOnes don't get threaded
   through when trying this special rule. TODO add this. *)
and tsELetAppArrayOperation g h x polyargs v1 v2 e =
  match v1, v2 with
    | VVar("getElem"),
      VExtend(VExtend(VEmpty,VBase(Str"0"),d), VBase(Str"1"),k) ->
      begin
        match refTermsOf g (ty (PEq (theV, WVal d))) with [URef(l)] -> begin
        match findHeapCell l h with Some(HConcObj(a,_,_)) -> begin
        match arrayTermsOf g (ty (PEq (theV, wVar a))) with [UArray(t)] -> begin
          if notAnIntString k then
            let e1 = eVar "getProp" in
            tsExp g h (ELet(x,None,EApp(polyargs,e1,EVal(v2)),e))
          else
            let sk = prettyStrVal k in
            err [spr "TS-GetElem: can't prove that [%s] is not an IntString" sk]
        end
        | []  -> err ["TS-GetElem: 0 array terms"]
        | _   -> err ["TS-GetElem: >1 array terms"]
        end
        | _  -> err ["TS-GetElem: heap constraint not found"]
        end
        | [] -> err ["TS-GetElem: 0 ref terms"]
        | _  -> err ["TS-GetElem: >1 ref terms"]
      end
    |  _ -> err ["function is not getElem"]
*)


(***** Value type conversion **************************************************)

and tcVal_ g h goal = function

  | (VBase _ as v)
  | (VVar _ as v)
  | (VEmpty as v)
  | (VExtend _ as v) ->
      let s = tsVal g h v in
      Sub.types (spr "TC-EVal: %s" (prettyStr strValue v)) g s goal

  | VFun(l,x,anno,e) ->
      let s = match anno with None -> "TC-Fun-Bare" | _ -> "TC-Fun-Ann" in
      tcVFun s g goal (l,x,anno,e)

and tcVFun ruleName g goal (l,x,anno,e) =
  let g = removeLabels g in
  let checkOne (((ts,ls,hs),y,t1,h1,t2,h2) as arr) =
    let u = UArr arr in
    Wf.typeTerm (spr "%s: arrow:\n  %s" ruleName (prettyStrTT u)) g ([],[]) u;
    let (ts,ls,hs) =
(* TODO requring all missing params now, since don't want to deal with
   heap prefix vars that get inserted...
      if l = ([],[],[]) then (ts,ls,hs) (* fill in omitted loc params *)
      else if l = (ts,ls,hs) then l
      else err [spr "%s: supplied poly params not equal to expected" ruleName]
*)
      if l = ([],[],[]) then (ts,ls,hs)
      else err ["lambda has some params..."]
    in
    let subst = ([(y, wVar x)], [], [], []) in
    let t2 = masterSubstTyp subst t2 in
    let h2 = masterSubstHeap subst h2 in
    let g = List.fold_left (fun acc x -> TVar(x)::acc) g ts in
    let g = List.fold_left (fun acc x -> LVar(x)::acc) g ls in
    let g = List.fold_left (fun acc x -> HVar(x)::acc) g hs in
    Zzz.pushScope ();
(*
    let (n,g) = snapshot g h1 in
    let (m,g) = tcAddBinding g h1 x t1 in
*)
    (* since input heap can refer to arg binders, need to process t1 first *)
    let (m,g) = tcAddBinding g h1 x t1 in
    let (n,g) = snapshot g h1 in
    (match anno with
       | None -> ()
       | Some(t,h) -> failwith "tc fun ann"
    );
    tcExp g h1 (t2,h2) e;
(*
    tcRemoveBinding ();
    tcRemoveBindingN n;
*)
    tcRemoveBindingN (n + m);
    Zzz.popScope ()
  in
(*
    Wf.wfLocFormalsFail ruleName l;
    let t2 = substVarInTyp x y t2 in
    let h1 = applyVarSubstHeap [x,y] h1 in
    let h2 = applyVarSubstHeap [x,y] h2 in
    Zzz.pushScope ();
    let (n,g) = snapshot g h1 in 
    let (g,h1) = tcAddBinding g h1 x (STyp t1) in
    (match anno with
       | None -> ()
       | Some(t,h) -> begin
           Wf.wfTypFail ruleName g h t;
           Wf.wfHeapFail ruleName g h1;
           Sub.checkTypes ruleName g TypeTerms.empty t1 t;
           ignore (Sub.checkHeapsFail ruleName g h1 h);
         end
    );
    tcExp g h1 (STyp t2, h2) e;
    tcRemoveBinding ();
    tcRemoveBindingN n;
    Zzz.popScope ();
  in 
*)
  match isArrows goal with 
    | Some(l) -> List.iter checkOne l
    | None    -> err [spr "%s: goal should be one or more arrows\n  %s"
                        ruleName (prettyStrTyp goal)]


(***** Expression type conversion *********************************************)

and tcExp_ g h goal = function

  | EVal(v) -> begin
      let (sGoal,hGoal) = goal in
      tcVal g h sGoal v;
      ignore (Sub.heaps (spr "TC-Val: %s" (prettyStrVal v)) g h hGoal)
    end

  | ELet(x,None,ENewref(l,EVal(v)),e) -> begin
(*
      failwith (spr "Tc elet newref goal: %s" (strWorld goal))
*)
      let cap = spr "TC-LetNewref-Bare: let %s = ..." x in
      let e = EAsW (cap, e, goal) in
      let w = tsExp g h (ELet(x,None,ENewref(l,EVal(v)),e)) in
(* 3/12 removing worlds
      ignore (Sub.worlds cap g w goal)
*)
      ()
(*
      let ruleName = "TC-LetNewref" in
      let strE = spr "  let %s = ref %s (%s) in ..." x l (prettyStrVal v) in
      let e = wrapWithGoal ruleName x e w in
      let w' = tsExp g h (ELet(x,None,ENewref(l,EVal(v)),e)) in
      niceCheckWorlds [ruleName; strE; strW] g w' w
*)
    end

  | EDeref(EVal(v)) -> begin
(*
      failwith "Tc deref"
*)
      let w = tsExp g h (EDeref(EVal(v))) in
      let cap = spr "TC-Deref: !(%s)" (prettyStrVal v) in
      ignore (Sub.worlds cap g w goal)
(*
      let ruleName = "TC-Deref" in
      let strE = spr "  !(%s)" (prettyStrVal v) in
      let w' = tsExp g h (EDeref(EVal(v))) in
      niceCheckWorlds [ruleName; strE; strW] g w' w
*)
    end

(*
  TODO 9/27 why was this case needed?
  | ELet(x,Some(a0),EDeref(EVal(v)),e) -> begin
      let ruleName = "TC-LetDeref" in
      let strE = spr "  let %s :: ... = !(%s) in ..." x (prettyStrVal v) in
      let e = wrapWithGoal ruleName x e a in
      let (s,h') = tsExp g h (ELet(x,Some(a0),EDeref(EVal(v)),e)) in
      let (s0,sGoal) = (scmOfAnn a0, scmOfAnn a) in     
      niceCheckSchemes [ruleName; strE; spr "checking s < s0"] g s s0;
      niceCheckSchemes [ruleName; strE; spr "checking s0 < goal"] g s0 sGoal;
      finishHeap [ruleName; strE] g h' a
    end
*)

  | ELet(x,None,ESetref(EVal(v1),EVal(v2)),e) -> begin
(*
      failwith (spr "Tc let setref: goal world:\n\n%s" (strWorld goal))
*)
      let cap = spr "TC-LetSetref-Bare: let %s = ..." x in
      let e = EAsW (cap, e, goal) in
      let w = tsExp g h (ELet(x,None,ESetref(EVal(v1),EVal(v2)),e)) in
(* 3/12 removing worlds
      ignore (Sub.worlds cap g w goal)
*)
      ()
(*
      let ruleName = "TC-LetSetref" in
      let strE = spr "  let %s = (%s) := (%s) in ..." x
                    (prettyStrVal v1) (prettyStrVal v2) in
      let e = wrapWithGoal ruleName x e w in
      let w' = tsExp g h (ELet(x,None,ESetref(EVal(v1),EVal(v2)),e)) in
      niceCheckWorlds [ruleName; strE; strW] g w' w
*)
    end

(*
  | EFreeze _ -> failwith "tc EFreeze"
*)

  | ELet(x,None,EApp(l,EVal(v1),EVal(v2)),e) -> begin
(*
      (* TODO wrap with goal *)
*)
      let (s1,s2) = (prettyStrVal v1, prettyStrVal v2) in
      let cap = spr "TC-LetApp: let %s = [...] (%s) (%s)" x s1 s2 in
      let e = EAsW (cap, e, goal) in
      let w = tsExp g h (ELet(x,None,EApp(l,EVal(v1),EVal(v2)),e)) in
(* 3/12 removing worlds
      ignore (Sub.worlds cap g w goal)
*)
      ()
(*
      (* TODO hmm, how to help the application, not just the body *)
      let ruleName = "TC-LetApp" in
      let strE = spr "  let %s = (%s) <%s> (%s) in ..."
                   x (prettyStrVal v1) (strLocs la) (prettyStrVal v2) in
      let e = wrapWithGoal ruleName x e w in
      let w' = tsExp g h (ELet(x,None,EApp(EVal(v1),la,EVal(v2)),e)) in
      niceCheckWorlds [ruleName; strE; strW] g w' w
*)
    end

  (* 9/21: special case added when trying to handle ANFed ifs *)
  (* 11/25: added this back in *)
  | ELet(x,None,e1,EVal(VVar(x'))) when x = x' -> begin
(*
      failwith "tc let special"
*)
      tcExp g h goal e1;
      (* adding binding just so the type is printed *)
      let (n,_) = tcAddBinding g (snd goal) x (fst goal) in
      tcRemoveBindingN n;
(*
      let ruleName = "TC-Let special" in
      let strE = spr "  let %s = ... in %s" x x in
      tcExp g h w e1;
      (* adding binding just so the type is printed *)
      ignore (tcAddBinding g (snd w) x (fst w));
      tcRemoveBinding ();
*)
    end

  | ELet(x,None,ENewObj(EVal(v1),l1,EVal(v),l2),e) -> begin
      let cap = spr "TC-NewObj: let %s = ..." x in
      let e = EAsW (cap, e, goal) in
      let w = tsExp g h (ELet(x,None,ENewObj(EVal(v1),l1,EVal(v),l2),e)) in
(* 3/12 removing worlds
      ignore (Sub.worlds cap g w goal)
*)
      ()
    end

  (***** all typing rules that use special let-bindings should be above *****)

  | ELet(x,None,e1,e2) -> begin
      (* TODO wrap with goal *)
(*
      let e2 = wrapWithGoal (spr "TC-Let: let %s = ..." x) e2 goal
*)

(* TODO post 11/25 *)
      let cap = spr "TC-Let: let %s = ..." x in
      let e2 = EAsW (cap, e2, goal) in
      let w = tsExp g h (ELet(x,None,e1,e2)) in
(* 3/12 removing worlds
      ignore (Sub.worlds cap g w goal)
*)
      ()

(* pre 11/25
      let w = tsExp g h (ELet(x,None,e1,e2)) in
      ignore (Sub.worlds (spr "TC-Let-Bare: let %s = ..." x) g w goal)
*)


(*
      let ruleName = "TC-Let" in
      let strE = spr "  let %s = ..." x in
      let e2 = wrapWithGoal ruleName x e2 w in
      let w' = tsExp g h (ELet(x,None,e1,e2)) in
      niceCheckWorlds [ruleName; strE; strW] g w' w
*)
    end

  | ELet(x,Some(a1),e1,e2) -> begin
      let ruleName = "TC-Let-Ann" in
      Wf.frame (spr "%s: let %s = ..." ruleName x) g a1;
      Zzz.pushScope ();
      let (s1,h1) = applyFrame h a1 in
      tcExp g h (s1,h1) e1;
      Zzz.popScope ();
      let (n,g1) = tcAddBinding g h1 x s1 in
      tcExp g1 h1 goal e2;
      tcRemoveBindingN n;
(*
      let ruleName = "TC-Let" in
      let strE = spr "  let %s = ..." x in
      let (h0,(s1,h1)) = applyAnnotation g h a1 in
      (* TODO change to wf annotation *)
      Wf.wfScmFail ruleName g h s1;
      Zzz.pushScope ();
      tcExp g h (s1,h1) e1;
      Zzz.popScope ();
      let h1 = h0 @ h1 in
      let (g,h1) = tcAddBinding g h1 x s1 in
      (* 9/23 added snapshot
         TODO might want to add bindings to the env without pushing their
         types, since they're already there? *)
      let (n,g) = snapshot g h1 in
      tcExp g h1 w e2;
      tcRemoveBindingN n;
      tcRemoveBinding ();
*)
    end

  | EIf(EVal(v),e1,e2) -> begin
      (* tcVal g h tyBool v; *)
      (* Zzz.pushForm (pGuard v true); *)
      tcVal g h tyAny v;
      Zzz.pushForm (pTruthy (WVal v));
      tcExp g h goal e1;  (* same g, since no new bindings *)
      Zzz.popForm ();
      (* Zzz.pushForm (pGuard v false); *)
      Zzz.pushForm (pFalsy (WVal v));
      tcExp g h goal e2; (* same g, since no new bindings *)
      Zzz.popForm ();
    end

  | EHeap(h,e) -> failwith "tc EHeap"

  | EExtern _ -> failwith "tc EExtern"

  | ETcFail(s,e) ->
      let fail =
        try let _ = tcExp g h goal e in false
        with Tc_error _ -> true in
      if fail
        then ()
        else err [spr "tc ETcFail: [\"%s\"] should have failed" s]

  | EAs(_,e,f) -> begin
      let w = applyFrame h f in
      tcExp g h w e;
      ignore (Sub.worlds "TC-EAs" g w goal)
    end

  | EAsW(_,e,w) -> begin
      tcExp g h w e;
      ignore (Sub.worlds "TC-EAsW" g w goal)
    end

  | ELabel(x,ao,e) -> begin
      tcExp (Lbl(x,Some(goal))::g) h goal e
(*
      (* TODO 9/28 completely ignoring the annotation. is this okay? *)
      tcExp (Label(x,Some(w))::g) h w e
*)
    end

  | EBreak(x,EVal(v)) -> begin
      let w = tsExp g h (EBreak(x,EVal(v))) in
      let cap = (spr "TC-Break: %s" x) in
      ignore (Sub.worlds cap g w goal)
    end

  | EFreeze _ -> failwith "tc EThrow"
  | EThaw _ -> failwith "tc ETryCatch"
  | ERefreeze _ -> failwith "tc ETryFinally"

  | EThrow _ -> failwith "tc EThrow"
  | ETryCatch _ -> failwith "tc ETryCatch"
  | ETryFinally _ -> failwith "tc ETryFinally"

  (* 11/26: going through a let-binding, since that's the only
     synthesis rule for new obj *)
  | ENewObj(EVal(v1),l1,EVal(v),l2) -> begin
      (* failwith "tc ENewObj: should've been checked with let-binding" *)

      let x = freshVar "_tc_newobj" in
      let w = tsExp g h (ELet(x,None,ENewObj(EVal(v1),l1,EVal(v),l2),eVar(x))) in
      let cap = spr "TC-NewObj: %s %s" (strLoc l1) (strLoc l2) in
      ignore (Sub.worlds cap g w goal)
(*
      failwith (spr "tc newobj, goal:\n%sj" (strWorld goal))
*)
    end

  (* the remaining cases should not make it to type checking, so they indicate
     some failure of parsing or ANFing *)

  | EBase _    -> Anf.badAnf "tc EBase"
  | EVar _     -> Anf.badAnf "tc EVar"
  | EDict _    -> Anf.badAnf "tc EDict"
  | EFun _     -> Anf.badAnf "tc EFun"
  | EIf _      -> Anf.badAnf "tc EIf"
  | EApp _     -> Anf.badAnf "tc EApp"
  | ENewref _  -> Anf.badAnf "tc ENewref"
  | EDeref _   -> Anf.badAnf "tc EDeref"
  | ESetref _  -> Anf.badAnf "tc ESetref"


(***** Entry point ************************************************************)

let addSkolems g =
  let n = Utils.IdTable.size idSkolems in
  let rec foo acc i =
    if i > n then acc
    else let sk = spr "_skolem_%d" i in
         foo (snd (tcAddBinding ~printHeap:false acc ([],[]) sk tyNum)) (i+1)
  in
  foo g 1

let typecheck e =
  let g = [] in
  let (_,g) = tcAddBinding ~printHeap:false g ([],[]) "v" tyAny in
  let g = addSkolems g in
  let (_,g) = tcAddBinding ~printHeap:false g ([],[]) "dObjectProto" tyEmpty in
  (* TODO *)
(*
  let (_,g) =
    tcAddBinding ~printHeap:false g ([],[]) xObjectPro (tyRef lObjectPro) in
*)
  let h = ([], [(lObjectPro, HConcObj ("dObjectProto", tyEmpty, lRoot))]) in
  try begin
    ignore (tsExp g h e);
    Sub.writeCacheStats ();
    let s = spr "OK! %d queries." !Zzz.queryCount in
    pr "\n%s\n" (Utils.greenString s)
  end with Tc_error(s) ->
    printTcErr s

let typecheck e =
  BNstats.time "typecheck" typecheck e

