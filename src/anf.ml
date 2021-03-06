
open Lang
open LangUtils


(***** A-Normalization ********************************************************)

(* - insert EVals in all places where the type system requires a value,
     by adding let bindings for all intermediate operations.
   - if desired, could do a little more work to check when creating a
     temporary is unnecessary because the rhs is already a value.
 *)

let freshTmp () = freshVar "_"

let rec mkExp (l,ebody) =
  match l with
    | (x,ao,e)::l' -> ELet (x, ao, e, mkExp (l',ebody))
    | []           -> ebody

(* 11/29: revamped ANF *)

let maybeTmp = function
  | EVal(v) -> ([], EVal v)
  | e       -> let z = freshTmp () in
               ([z,None,e], eVar z)

(* adding additional let bindings to satisfy what tc expects *)
(* TODO remove this once tc uses existentials everywhere *)
let finish (l,e) =
  let b = match e with
            | EApp _ | ENewref _ | ESetref _ -> true
            | _ -> false in
  if b
  then let z = freshTmp () in (l @ [z,None,e], eVar z)
  else (l, e)

let rec anf = function
  | EVal({value=VFun(x,e)}) -> ([], EVal (vFun (x, anfExp e)))
  | EVal(w) -> ([], EVal w)
  | EDict(xel) ->
      let (ll,xwl) =
        xel |> List.map (fun (e1,e2) ->
                 let (l1,e1) = anfAndTmp e1 in
                 let (l2,e2) = anfAndTmp e2 in
                 (match e1, e2 with
                    | EVal(w1),EVal(w2) -> (l1@l2, (w1,w2))
                    | _  -> failwith "anf: expr in dict not value?"))
            |> List.split
      in
      let vdict =
        List.fold_left
          (fun acc (w1,w2) -> wrapVal pos0 (VExtend (acc, w1, w2)))
          (wrapVal pos0 VEmpty) xwl
      in
      finish (List.concat ll, EVal vdict)
(* TODO want to use this version, but the special let rule in TcDref
   currently requires the version below.
  | EIf(e1,e2,e3) ->
      let (l1,e1) = anfAndTmp e1 in
      finish (l1, EIf (e1, anfExp e2, anfExp e3))
*)
  | EArray(t,el) ->
      let (ll,vl) = el |> List.map anfAndTmp |> List.split in
      let vl =
        List.map
          (function EVal(v) -> v | _ -> failwith "anf: expr in arr?") vl in
      finish (List.concat ll, EVal ({pos=pos0; value=VArray (t, vl)}))
  | ETuple(el) ->
      let (ll,vl) = el |> List.map anfAndTmp |> List.split in
      let vl =
        List.map
          (function EVal(v) -> v | _ -> failwith "anf: expr in tuple?") vl in
      finish (List.concat ll, EVal ({pos=pos0; value=VTuple vl}))
  | EIf(e1,e2,e3) ->
      let (l1,e1') = anf e1 in
      let z1 = freshTmp () in
      let z23 = freshTmp () in
      let l' = [(z1, None, e1');
                (z23, None, EIf (eVar z1, anfExp e2, anfExp e3))] in
      (l1 @ l', eVar z23)
  | EApp(appargs,e1,e2) ->
      let (l1,e1) = anfAndTmp e1 in
      let (l2,e2) = anfAndTmp e2 in
      finish (l1 @ l2, EApp (appargs, e1, e2))
  | ELet(x,ao,e1,e2) ->
      (* history of versions used:             I
                                               II
                                     09/06/11: III
                                     11/01/11: I
                                               III
                                     08/14/12: I
                                     09/03/12: II
                                     09/04/12: I
      *)
      if true then                                  (* version I *)
        ([], ELet (x, ao, anfExp e1, anfExp e2))
      else if true then                             (* version II *)
        let (l1,e1) = anf e1 in
        (l1, ELet (x, ao, e1, anfExp e2))
      else                                          (* version III *)
        let (l1,e1) = anf e1 in
        let (l2,e2) = anf e2 in
        (l1 @ [x, ao, e1] @ l2, e2)
  | EExtern(x,s,e) -> ([], EExtern (x, s, anfExp e))
  | EHeapEnv(l,e) -> ([], EHeapEnv (l, anfExp e))
  | EMacro(x,m,e) -> ([], EMacro (x, m, anfExp e))
  | ETcFail(s,e) -> ([], ETcFail (s, anfExp e))
  (* | EAs(e,a) -> ([], EAs (anfExp e, a)) *)
  | EAsW(e,a) -> ([], EAsW (anfExp e, a))
  | ENewref(cl,e,ci) ->
      let (l,e) = anfAndTmp e in
      finish (l, ENewref (cl, e, ci))
  | EDeref(e) ->
      let (l,e) = anfAndTmp e in
      finish (l, EDeref e)
  | ESetref(e1,e2) ->
      let (l1,e1) = anfAndTmp e1 in
      let (l2,e2) = anfAndTmp e2 in
      finish (l1 @ l2, ESetref (e1, e2))
  | EWeak(h,e) -> ([], EWeak (h, anfExp e))
  | ELabel(x,e) -> ([], ELabel (x, anfExp e))
  | EBreak(x,e) ->
      let (l,e) = anfAndTmp e in
      (l, EBreak (x, e))
  | ETryCatch(e1,x,e2) -> ([], ETryCatch (anfExp e1, x, anfExp e2))
  | ETryFinally(e1,e2) -> ([], ETryFinally (anfExp e1, anfExp e2))
  | EThrow(e) ->
      let (l,e) = anfAndTmp e in
      finish (l, EThrow e)
  | ENewObj(e1,loc1,e2,loc2,ci) ->
      let (l1,e1) = anfAndTmp e1 in
      let (l2,e2) = anfAndTmp e2 in
      finish (l1 @ l2, ENewObj (e1, loc1, e2, loc2, ci))
  | ELoadedSrc(s,e) -> ([], ELoadedSrc (s, anfExp e))
  | EFreeze(loc,x,e) ->
      let (l,e) = anfAndTmp e in
      finish (l, EFreeze (loc, x, e))
  | EThaw(loc,e) ->
      let (l,e) = anfAndTmp e in
      finish (l, EThaw (loc, e))
  | ELoadSrc _ -> failwith "Anf.anf: ELoadSrc should've been expanded"

and anfAndTmp e =
  let (l1,e) = anf e in
  let (l2,e) = maybeTmp e in
  (l1 @ l2, e)

and anfExp e = mkExp (anf e)

(* Clean up the results of ANFing a bit.

     let _tmp = e1 in
     let y = _tmp in e2    =>  let y = e1 in e2

     let _tmp = e in _tmp  =>  e
*)
let removeUselessLets = function
  | ELet(x,None,e1,ELet(y,None,EVal({value=VVar(x')}),e2))
    when x = x' && x.[0] = '_' ->
      ELet (y, None, e1, e2)
  | ELet(x,None,e,EVal({value=VVar(x')})) when x = x' -> e
  | e -> e

let anfExp e = e |> anfExp |> mapExp removeUselessLets


(***** A-Normalized program printer *******************************************)

(* The return value of strVal and strExp is expected to be aligned at the
   nesting level k. The caller can clip any leading whitespace if it wants
   to include the first line of the return value on the current line.
*)

let badAnf s = failwith (spr "[%s] ANFer did something wrong here" s)

let noLineBreaks s = not (String.contains s '\n')

let clip = Utils.clip

let tab k = String.make (2 * k) ' '

let rec strVal_ k = function
  | VVar(x) -> spr "%s%s" (tab k) x
  | VFun(x,e) -> strLam k x e
  | VNull -> spr "%snull" (tab k)
  | VBase(c) -> spr "%s%s" (tab k) (strBaseValue c)
  (* | VEmpty -> spr "%s{}" (tab k) *)
  | VEmpty -> spr "%sempty" (tab k)
  | VExtend(v1,v2,v3) ->
      let s1 = strVal k v1 in
      let s2 = strVal k v2 in
      let s3 = strVal k v3 in
      (* spr "%s(upd %s %s %s)" (tab k) (clip s1) (clip s2) (clip s3) *)
      spr "%s(%s with %s = %s)" (tab k) (clip s1) (clip s2) (clip s3)
  | VArray(t,vs) ->
      let st = if t = tyArrDefault then "" else spr " as Arr(%s)" (strTyp t) in
      (* let st = spr " as %s" (strTyp t) in *)
      let svs = List.map (fun s -> clip (strVal k s)) vs in
      spr "%s<%s>%s" (tab k) (String.concat ", " svs) st 
  | VTuple([v]) -> spr "%s(%s,)" (tab k) (clip (strVal k v)) (* 8/31/12 *)
  | VTuple(vs) ->
      let svs = List.map (fun s -> clip (strVal k s)) vs in
      spr "%s(%s)" (tab k) (String.concat ", " svs)

and strVal k v = strVal_ k v.value

and strLam k pat e =
  let sexp = strExp (succ k) e in
  if noLineBreaks sexp
    then spr "%sfun %s -> (%s)" (tab k) (strPat pat) (clip sexp)
    else spr "%sfun %s -> (\n%s\n%s)" (tab k) (strPat pat) sexp (tab k)

(* TODO for better formatting, should always check for newlines before clipping *)
and strExp k exp = match exp with
  | EVal(w) -> strVal k w
  | EIf(EVal(w1),e2,e3) ->
      spr "%sif %s then \n%s\n%selse \n%s"
        (tab k) (clip (strVal k w1))
          (strExp (succ k) e2)
        (tab k)
          (strExp (succ k) e3)
  | EApp(([],[],[]),EVal(w1),EVal(w2)) ->
      let s1 = strVal k w1 in
      let s2 = strVal k w2 in
      spr "%s%s(%s)" (tab k) (clip s1) (clip s2)
  | EApp((ts,ls,hs),EVal(w1),EVal(w2)) ->
      let s1 = strVal k w1 in
      let s2 = strVal k w2 in
      let s0 = spr "[ %s; %s; %s ]" (* first space in particular to avoid [[ *)
                 (String.concat "," (List.map strTyp ts))
                 (strLocs ls)
                 (String.concat "," (List.map strHeap hs)) in
      spr "%s(%s %s)(%s)" (tab k) s0 (clip s1) (clip s2)
  | ELet(x,ao,e1,e2) ->
      let sep = if k = 0 then "\n\n" else "\n" in
      let sao =
        match ao with
          | None -> ""
          | Some([x],h1,(t2,h2)) when h1 = ([x],[]) && h1 = h2 ->
              spr " :: %s" (strTyp t2)
          | Some(a) -> spr " ::: %s" (strFrame a)
      in
      let s1 = strExp (succ k) e1 in
      let s2 = strExp k e2 in
      if noLineBreaks s1
        then spr "%slet %s%s = %s in%s%s" (tab k) x sao (clip s1) sep s2
        else spr "%slet %s%s =\n%s in%s%s" (tab k) x sao s1 sep s2
  (* TODO For Extern, Assert, and Assume, print str_ in flat mode *)
  | EExtern(x,s,e) ->
      let sep = if x = "end_of_dref_basics" ||
                   x = "end_of_dref_objects" ||
                   x = "end_of_js_natives" ||
                   x = "__end_of_djs_prelude"
                then spr "(%s)\n\n" (String.make 78 '*')
                else "" in
      spr "%sval %s :: %s\n\n%s%s" (tab k) x (clip (strTyp s)) sep (strExp k e)
  | EHeapEnv(l,e) ->
      let sep = if k = 0 then "\n\n" else "\n" in
      spr "%sheap (\n%s%s\n%s)%s%s"
        (tab k) (tab (succ k))
        (clip (String.concat (spr ",\n%s" (tab (succ k)))
                             (List.map strHeapEnvBinding l)))
        (tab k) sep (strExp k e)
  | EMacro(x,m,e) ->
      let s =
        match m with
          | MacroT(t) -> spr "= %s" (strTyp t)
          | MacroTT(tt) -> spr ":: %s" (strTT tt) in
      let sep = if k = 0 then "\n\n" else "\n" in
      spr "%stype %s %s%s%s%s" (tab k) x s sep (tab k) (strExp k e)
  | ETcFail(s,e) ->
      spr "%s(fail \"%s\" \n%s)" (tab k) s (strExp (succ k) e)
(*
  | EAs(e,f) ->
      let sf = strFrame f in
      spr "%s(%s\n%s) as %s" (tab k) (clip (strExp k e)) (tab k) sf
*)
  | EAsW(e,w) ->
      let sw = strWorld w in
      spr "%s(%s\n%s) as %s" (tab k) (clip (strExp k e)) (tab k) sw
  | ENewref(x,e,ci) ->
      spr "%sref (%s, %s, %s)" (tab k) (strLoc x) (clip (strExp k e))
        (match ci with Some(t) -> strTyp t | None -> "_")
  | EDeref(e) -> spr "%s(!%s)" (tab k) (clip (strExp k e))
  (* TODO split lines? *)
  | ESetref(e1,e2) ->
      let s1 = strExp k e1 in
      let s2 = strExp k e2 in
      spr "%s%s := %s" (tab k) (clip s1) (clip s2)
  | EWeak(h,e) -> spr "%sweak %s\n\n%s" (tab k) (strWeakLoc h) (strExp k e)
  | ELabel(x,e) ->
      let se = strExp (succ k) e in
      spr "%s#%s {\n%s\n%s}" (tab k) x se (tab k)
  | EBreak(x,e) ->
      let s = strExp (succ k) e in
      spr "%sbreak #%s %s" (tab k) x (clip s)
  | EThrow(e) ->
      let s = strExp (succ k) e in
      spr "%sthrow %s" (tab k) (clip s)
  (* TODO put block on single line if short enough *)
  | ETryCatch(e1,x,e2) ->
      let (s1,s2) = strExp (succ k) e1, strExp (succ k) e2 in
      spr "%stry {\n%s\n%s} catch (%s) {\n%s\n%s}" (tab k) s1 (tab k) x s2 (tab k)
  | ETryFinally(e1,e2) ->
      let (s1,s2) = strExp (succ k) e1, strExp (succ k) e2 in
      spr "%stry {\n%s\n%s} finally {\n%s\n%s}" (tab k) s1 (tab k) s2 (tab k)
  | ENewObj(EVal(v1),l1,EVal(v2),l2,ci) ->
      let s1 = strVal (succ k) v1 in
      let s2 = strVal (succ k) v2 in
      spr "%snew (%s, %s, %s, %s, %s)"
        (tab k) (clip s1) (strLoc l1) (clip s2) (strLoc l2)
        (match ci with Some(t) -> strTyp t | None -> "_")
  | EFreeze(l,x,EVal(v)) ->
      let sx = strThawState x in
      spr "%sfreeze (%s, %s, %s)" (tab k) (strLoc l) sx (clip (strVal (succ k) v))
  | EThaw(l,EVal(v)) ->
      spr "%sthaw (%s, %s)" (tab k) (strLoc l) (clip (strVal (succ k) v))
  | EDict _        -> badAnf "EDict"
  | ETuple  _      -> badAnf "ETuple"
  | EArray _       -> badAnf "EArray"
  | EIf _          -> badAnf "EIf"
  | EApp _         -> badAnf "EApp"
  | ENewObj _      -> badAnf "ENewObj"
  | EFreeze _      -> badAnf "EFreeze"
  | EThaw _        -> badAnf "EThaw"
  | ELoadSrc _     -> failwith "Anf.strExp: ELoadSrc should've been expanded"
  | ELoadedSrc(s,e) ->
      let s = Str.replace_first (Str.regexp Settings.djs_dir) "DJS_DIR/" s in
      let n = max 0 (70 - String.length s) in
      let sep = spr "(***** %s %s*)" s (String.make n '*') in
      spr "%s%s\n\n%s" (tab k) sep (strExp k e)

let printAnfExp e =
  let oc = open_out (Settings.out_dir ^ "anfExp.dref") in
  fpr oc "%s\n" (strExp 0 e);
  flush oc;
  ()


(***** Coercion from expression to ANF expression *****************************)

(* When a source file is processed "raw", it is expected to be in ANF.
   Instead of requiring the parser to check that the things that should be
   values are indeed values, allow the parser to be oblivious about raw
   mode; that is, allow it to produce E- versions of expressions everywhere.
   But then have the expression go through this coercion to ANF.
   Alternatively, could have a duplicate version of the parser that only
   accepts A-normal programs. *)

let rec coerceVal e =
  match coerce e with
    | EVal(w) -> w
    | _       -> failwith "coerceVal"

and coerceEVal from e =
  match coerce e with
    | EVal(w) -> EVal w
    | _       -> failwith (spr "coerceEVal: called from %s" from)

and coerce = function
  | EVal({value=VFun(x,e)}) -> EVal (vFun (x, coerce e))
  | EVal(w) -> EVal w
  | EDict([]) -> EVal (wrapVal pos0 VEmpty)
  | EDict _ -> failwith "Anf.coerce EDict: should have become calls to set"
  | EArray(t,es) -> EVal (wrapVal pos0 (VArray (t, List.map coerceVal es)))
  | ETuple(es) -> EVal (wrapVal pos0 (VTuple (List.map coerceVal es)))
  | EIf(e1,e2,e3) -> EIf (coerceEVal "if" e1, coerce e2, coerce e3)
  | EApp(l,e1,e2) -> EApp (l, coerceEVal "app1" e1, coerceEVal "app2" e2)
  | ELet(x,ao,e1,e2) -> ELet (x, ao, coerce e1, coerce e2)
  | EExtern(x,s,e) -> EExtern (x, s, coerce e)
  | EHeapEnv(l,e) -> EHeapEnv (l, coerce e)
  | EMacro(x,m,e) -> EMacro (x, m, coerce e)
  | ETcFail(s,e) -> ETcFail (s, coerce e)
  | EAsW(e,w) -> EAsW (coerce e, w)
  | ENewref(cl,e,ci) -> ENewref (cl, coerce e, ci)
  | EDeref(e) -> EDeref (coerceEVal "deref" e)
  | ESetref(e1,e2) -> ESetref (coerceEVal "setref1" e1, coerceEVal "setref2" e2)
  | EWeak(h,e) -> EWeak (h, coerce e)
  | ELabel(x,e) -> ELabel (x, coerce e)
  | EBreak(x,e) -> EBreak (x, coerceEVal "break" e)
  | EThrow(e) -> EThrow (coerceEVal "throw" e)
  | ETryCatch(e1,x,e2) -> ETryCatch (coerce e1, x, coerce e2)
  | ETryFinally(e1,e2) -> ETryFinally (coerce e1, coerce e2)
  | ENewObj(e1,l1,e2,l2,ci) ->
      ENewObj (coerceEVal "NewObj" e1, l1, coerceEVal "NewObj" e2, l2, ci)
  | ELoadSrc(s,e) -> ELoadSrc (s, coerce e)
  | ELoadedSrc(s,e) -> ELoadedSrc (s, coerce e)
  | EFreeze(l,x,e) -> EFreeze (l, x, coerceEVal "EFreeze" e)
  | EThaw(l,e) -> EThaw (l, coerceEVal "EThaw" e)

