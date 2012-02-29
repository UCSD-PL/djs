
open Lang
open LangUtils

module E = Exprjs_syntax
module J = JavaScript_syntax
module L = Lambdajs_syntax

module IdMap = Prelude.IdMap
module IdSet = Prelude.IdSet
module IdSetExt = Prelude.IdSetExt

module StrSet = Utils.StrSet


(***** Check variable scopes **************************************************)

exception NeedVarLifting of Prelude.id * Prelude.id
exception NeedImplicitGlobal of Prelude.id * Prelude.id

let rec foo curFunc lexScope varScope = function
  | E.VarExpr (_, x) ->
      if        not (IdSet.mem x lexScope) &&
                IdSet.mem x varScope &&
                not (!Settings.doVarLifting) then
                  raise (NeedVarLifting (curFunc, x))
      else if   not (IdSet.mem x lexScope) &&
                not (IdSet.mem x varScope) &&
                not (!Settings.doImplicitGlobal) then
                  raise (NeedImplicitGlobal (curFunc, x))
      else      lexScope
  | E.FuncExpr (_, l, e) ->
      let env = E.locals e in
      let newLexScope  =
        List.fold_left (fun acc x -> IdSet.add x acc) lexScope l in
      let _ = foo (spr "%s.ANON_FUNC" curFunc) newLexScope env e in
      lexScope
  | E.FuncStmtExpr (_, f, l, e) ->
      let env = E.locals e in
      let newLexScope  =
        IdSet.add f
          (List.fold_left (fun acc x -> IdSet.add x acc) lexScope l) in
      let _ = foo (spr "%s.ANON_FUNC" curFunc) newLexScope env e in
      newLexScope
  | E.ConstExpr _
  | E.ThisExpr _ -> lexScope
  | E.ArrayExpr (_, es) -> fooFold curFunc lexScope varScope es
  | E.ObjectExpr (_, ps) ->
      let es = List.map (fun (_,_,e) -> e) ps in
      fooFold curFunc lexScope varScope es
  (* TODO look at this and djsLite/fail/fail06.js *)
  | E.IdExpr _ -> failwith "checkVars idexpr"
  | E.NewExpr (_, c, args) ->
      let _ = fooIter curFunc lexScope varScope args in
      lexScope
  | E.PrefixExpr (_, _, e)
  | E.ThrowExpr (_, e)
  | E.HintExpr (_, _, e) -> foo curFunc lexScope varScope e
  | E.BracketExpr (_, e1, e2)
  | E.InfixExpr (_, _, e1, e2) -> fooFold curFunc lexScope varScope [e1;e2]
  | E.ForInExpr (_, _, e1, e2)
  | E.WhileExpr (_, e1, e2)
  | E.DoWhileExpr (_, e1, e2) ->
      (* shouldn't accumulate lexScope, right? *)
      let _ = fooIter curFunc lexScope varScope [e1;e2] in
      lexScope
  | E.IfExpr (_, e1, e2, e3) ->
      let _ = fooIter curFunc lexScope varScope [e1;e2;e3] in
      lexScope
  | E.AssignExpr (_, l, e) ->
      foo curFunc (fooLv curFunc lexScope varScope l) varScope e
  | E.AppExpr (_, f, args) -> fooFold curFunc lexScope varScope (f::args)
  | E.LetExpr (_, x, e1, e2) -> 
      (* rkc: not sure if x needs to be added or not *)
      fooFold curFunc (IdSet.add x lexScope) varScope [e1;e2]
  | E.SeqExpr (_, e1, e2) ->
      fooFold curFunc lexScope varScope [e1;e2]
  | E.LabelledExpr (_, _, e) -> foo curFunc lexScope varScope e
  | E.BreakExpr (_, _, e) -> foo curFunc lexScope varScope e
  | E.VarDeclExpr (_, x, e) ->
      IdSet.add x (foo curFunc lexScope varScope e)
  | E.TryCatchExpr (_, e1, _, e2) -> (* TODO catch bound identifiers *)
      fooFold curFunc lexScope varScope [e1;e2]
  | E.TryFinallyExpr (_, e1, e2) ->
      fooFold curFunc lexScope varScope [e1;e2]
(*
  | E.FuncStmtExpr (_, f, _, _) -> IdSet.singleton f
*)

and fooLv curFunc lexScope varScope = function
    E.VarLValue _ -> lexScope
  | E.PropLValue (_, e1, e2) -> fooFold curFunc lexScope varScope [e1;e2]

(* chain scopes together *)
and fooFold curFunc lexScope varScope es =
  List.fold_left (fun acc -> foo curFunc acc varScope) lexScope es

(* don't chain scopes together *)
and fooIter curFunc lexScope varScope es =
  List.iter (fun e -> ignore (foo curFunc lexScope varScope e)) es

let checkVars e =
  try ignore (foo "TOP_LEVEL" IdSet.empty IdSet.empty e)
  with NeedVarLifting(foo,x) ->
         printParseErr (spr
           "function [%s] refers to [%s] before declaration\n\n\
            to enable variable lifting: -varLifting true"
              foo x)
     | NeedImplicitGlobal(foo,x) ->
         printParseErr (spr
           "function [%s] refers to [%s] that is not declared\n\n\
            to enable implicit reads/writes to global: -implicitGlobal true"
              foo x)


(***** Label munging **********************************************************)

(* This maps an EJS.expr to a new EJS.expr, doing two things:
   - creating unique ret/break/continue labels
   - recording which break/continue labels are actually jumped to
   - removing all '%' characters are removed from labels inserted by JS->EJS
*)

(* if s is of the form "%blah", return "blah" *)
let trimLabel s =
  if s = "" then ""
  else if s.[0] = '%' then String.sub s 1 (String.length s - 1)
  else s

let mkRetLabel     = let c = ref 0 in fun () -> incr c; spr "return_%d" (!c)
let mkBreakLabel   = let c = ref 0 in fun () -> incr c; spr "break_%d" (!c)
let mkContLabel    = let c = ref 0 in fun () -> incr c; spr "continue_%d" (!c)

let isBreakLabel s = Str.string_match (Str.regexp "^break_.*$") s 0
let isContLabel s  = Str.string_match (Str.regexp "^continue_.*$") s 0

let retStack       = ref ["return_XXXX"]
let breakStack     = ref ["break_XXXX"]
let contStack      = ref ["continue_XXXX"]

let push x stack   = stack := x :: (!stack)
let pop stack      = stack := List.tl (!stack)
let top stack      = List.hd (!stack)

let jumpedTo       = ref StrSet.empty

let rec fooLabelledExpr p x e stack =
  push x stack;
  let e = foo e in
  pop stack;
  E.LabelledExpr (p, x, e)

and foo e = match e with
  | E.VarExpr _ | E.IdExpr _ | E.ConstExpr _ | E.ThisExpr _ -> e
  | E.LabelledExpr (p, x, e) ->
      if x = "%return" then fooLabelledExpr p (mkRetLabel ()) e retStack
      else if x = "%break" then fooLabelledExpr p (mkBreakLabel ()) e breakStack
      else if x = "%continue" then fooLabelledExpr p (mkContLabel ()) e contStack
      else E.LabelledExpr (p, trimLabel x, foo e)
  | E.BreakExpr (p, x, e) -> begin
      let x =
        if x = "%return" then top retStack
        else if x = "%break" then top breakStack
        else if x = "%continue" then top contStack
        else trimLabel x in
      jumpedTo := StrSet.add x !jumpedTo;
      E.BreakExpr (p, x, foo e)
    end
  | E.ArrayExpr (p, es) -> E.ArrayExpr (p, List.map foo es)
  | E.ObjectExpr (p, ps) ->
      E.ObjectExpr (p, List.map (fun (p,f,e) -> (p, f, foo e)) ps)
  | E.NewExpr (p, e, es) -> E.NewExpr (p, foo e, List.map foo es)
  | E.PrefixExpr (p, x, e) -> E.PrefixExpr (p, x, foo e)
  | E.ThrowExpr (p, e) -> E.ThrowExpr (p, foo e)
  | E.HintExpr (p, s, e) -> E.HintExpr (p, s, foo e)
  | E.BracketExpr (p, e1, e2) -> E.BracketExpr (p, foo e1, foo e2)
  | E.InfixExpr (p, x, e1, e2) -> E.InfixExpr (p, x, foo e1, foo e2)
  | E.ForInExpr (p, x, e1, e2) -> E.ForInExpr (p, x, foo e1, foo e2)
  | E.WhileExpr (p, e1, e2) -> E.WhileExpr (p, foo e1, foo e2)
  | E.DoWhileExpr (p, e1, e2) -> E.DoWhileExpr (p, foo e1, foo e2)
  | E.IfExpr (p, e1, e2, e3) -> E.IfExpr (p, foo e1, foo e2, foo e3)
  | E.AssignExpr (p, l, e) -> E.AssignExpr (p, fooLv l, foo e)
  | E.FuncExpr (p, l, e) -> E.FuncExpr (p, l, foo e)
  | E.AppExpr (p, e, es) -> E.AppExpr (p, foo e, List.map foo es)
  | E.LetExpr (p, x, e1, e2) -> E.LetExpr (p, x, foo e1, foo e2)
  | E.SeqExpr (p, e1, e2) -> E.SeqExpr (p, foo e1, foo e2)
  | E.VarDeclExpr (p, x, e) -> E.VarDeclExpr (p, x, foo e)
  | E.TryCatchExpr (p, e1, x, e2) -> E.TryCatchExpr (p, foo e1, x, foo e2)
  | E.TryFinallyExpr (p, e1, e2) -> E.TryFinallyExpr (p, foo e1, foo e2)
  | E.FuncStmtExpr(p,x,l,e) -> E.FuncStmtExpr (p, x, l, foo e)

and fooLv = function
  | E.VarLValue (p, x) -> E.VarLValue (p, x)
  | E.PropLValue (p, e1, e2) -> E.PropLValue (p, foo e1, foo e2)

let freshenLabels e = foo e


(***** DJS macros *************************************************************)

let oc_macros = open_out (Settings.out_dir ^ "macros.txt")
let debugMacros = true

let macroTable = Hashtbl.create 17
let macroDefs = Hashtbl.create 17

let rec expandMacros s =
  let s' =
    Hashtbl.fold
      (fun x y acc -> Str.global_replace (Str.regexp x) y acc)
      macroTable s 
  in
  if s = s' then s else expandMacros s'

let expandMacros s =
  let s' = expandMacros s in
  if debugMacros && s <> s'
  then fpr oc_macros "%s\n%s\n--->\n%s\n\n" (String.make 80 '-') s s'
  else ();
  s'

let parseMacroDef sOrig =
  let s = Utils.clip sOrig in
  let s = Str.replace_first (Str.regexp "\n") " " s in
  try begin
    if Utils.strPrefix s "#define" then
      let n = String.length "#define " in
      let s = String.sub s n (String.length s - n) in
      let (macro,defn) = Utils.splitAround s ' ' in (* may raise Not_found *)
      let defn = expandMacros defn in (* allow previous macros to be used *)
      let _ = Hashtbl.add macroTable macro defn in
      let _ = Hashtbl.add macroDefs sOrig macro in
      let _ =
        if debugMacros
        then fpr oc_macros "%s\ndef [%s]\n\n%s\n" (String.make 80 '-') macro defn
        else () in
      Some (macro, defn)
    else 
      None
  end with Not_found -> None

let rec collectMacros = function
  (* /*: #define name T */ '#define'; *)
  | E.HintExpr (_, s, E.ConstExpr (_, J.CString "#define"))
  (* '#define name T'; *)
  | E.ConstExpr (_, J.CString(s)) -> ignore (parseMacroDef s)
  | E.SeqExpr (_, e1, e2)         -> (collectMacros e1; collectMacros e2)
  | _                             -> ()


(***** Parsing DJS annotations ************************************************)

let parseWith production cap s =
  let s = expandMacros s in
  try production LangLexer.token (Lexing.from_string s)
  with Lang.Parse_error(x) ->
         printParseErr (spr "couldn't parse annotation as [%s]:\n\n[%s]\n\n%s"
           cap s x)
     | LangParser.Error -> (* menhir *)
         printParseErr (spr "couldn't parse annotation as [%s]:\n\n[%s]"
           cap s)

let parseTyp s     = parseWith LangParser.jsTyp "typ annot" s
let parseAppArgs s = parseWith LangParser.jsPolyArgs "typ/loc/heap args" s
let parseWhile s   = parseWith LangParser.jsWhile "while annot" s
let parseLoc s     = parseWith LangParser.jsLoc "loc annot" s
let parseCtorTyp s = parseWith LangParser.jsCtor "ctor annot" s
let parseNew s     = parseWith LangParser.jsNew "new annot" s
let parseArrLit s  = parseWith LangParser.jsArrLit "array literal annot" s
let parseObjLocs s =
  match parseWith LangParser.jsObjLocs "obj loc annot" s with
    | l1, Some(l2) -> (l1, l2)
    | l1, None     -> (l1, lObject)

let maybeParseWith production s =
  let s = expandMacros s in
  try Some (production LangLexer.token (Lexing.from_string s))
  with Lang.Parse_error _ | LangParser.Error -> None

let maybeParseTcFail s  = maybeParseWith LangParser.jsFail s


(***** Desugaring types *******************************************************)

let oc_desugar_hint = open_out (Settings.out_dir ^ "desugar_hint.txt")

(*
let expandAwayTyp t =
  let x = freshVar "_ugh" in
  TRefinement (x, applyTyp t (wVar x))

let expandAwayHeap (hs,cs) =
  let cs =
    List.map (function
      | (l,HConc(x,s)) -> (l, HConc (x, expandAwayTyp s))
      | (l,HConcObj(x,s,l')) -> (l, HConcObj (x, expandAwayTyp s, l'))
    ) cs
  in
  (hs, cs)

let expandAwayDepTuples (t,h) =
  (expandAwayTyp t, expandAwayHeap h)

let depTupleSubst t w =
  let rec foo acc path = function
    | TTuple(l) -> 
        Utils.fold_left_i (fun acc (x,t) i ->
          let path = sel path (wProj i) in
          let acc = (x, path) :: acc in
          foo acc path t
        ) acc l
    | TNonNull(t) | TMaybeNull(t) -> foo acc path t
    | _ -> acc
  in
  List.rev (foo [] w t)
*)

(* all [typArgs; locArgs, l_this, l_args; heapArgs].
       (Ref(l_this) * Ref(l_args))
     / [inH ++ inC, l_this |-> c_this: TOP, l_args |-> c_args: tIn] 
    -> tRet
     / [outH ++ outC, l_this |-> c_this': TOP]
*)
let dsArrow arr =

  let arr = ParseUtils.maybeAddHeapPrefixVar arr in
  let ((ts,ls,hs),x,tIn,(inH,inC),tRet,(outH,outC)) = arr in

  let (tyThis,tIn) =
    match tIn with
      | TTuple(("this",THasTyp(URef(lThis)))::tup) ->
          ([("this", tyRef lThis)], TTuple tup)
      | _ ->
          ([], tIn) in

  let (lArgs,cArgs) = (freshVar "Largs", freshVar "cArgs") in

  let formalSubst = [(x, wVar cArgs)] in

(*
  (* NOTE: would like to _not_ substitute away tuple binders, but am
     doing it for now. see 11/27/11 notes.txt entry. *)
  let formalSubst = formalSubst @ depTupleSubst tIn (wVar c_args) in
  let (tIn,(inH,inC)) = expandAwayDepTuples (tIn,(inH,inC)) in
*)

  fpr oc_desugar_hint "formalSubst:\n%s\n"
    (String.concat "" (List.map (fun (x,w) -> spr "  %s |-> %s\n"
       x (prettyStrWal w)) formalSubst));

  let argsCell  = (LocVar lArgs, HConc (cArgs, tIn)) in

  let subst = (formalSubst, [], [], []) in
  let inC   = snd (masterSubstHeap subst ([],inC)) @ [argsCell] in
  let outC  = snd (masterSubstHeap subst ([],outC)) @ [] in
  let tRet  = masterSubstTyp subst tRet in

  let tyArgs = [("arguments", tyRef (LocVar lArgs))] in

  ((ts, ls @ [lArgs], hs),
   freshVar "_",
   TTuple (tyThis @ tyArgs), (inH,inC),
   tRet, (outH,outC))

let dsTyp t =
  let fTT = function
    | UArr(arr) -> UArr (dsArrow arr)
    | u         -> u in
  mapTyp ~fTT t

let desugarTypHint hint =
  (* let err x = printParseErr (spr "desugarScm\n\n%s\n\n%s" cap x) in *)
  match maybeParseTcFail hint with
    | Some(s) -> printParseErr "TODO DJS failure annotations not implemented"
    | None -> begin
        fpr oc_desugar_hint "%s\n" (String.make 80 '-');
        fpr oc_desugar_hint "hint: [%s]\n\n" hint;
        let t = parseTyp hint in
        let t' = dsTyp t in
        if t <> t' then fpr oc_desugar_hint "%s\n\n" (prettyStr strTyp t');
        t'
      end

let desugarCtorHint hint =
  let arr = parseCtorTyp hint in
  dsTyp (THasTyp (UArr arr))

(* TODO for now, not allowing intersections of arrows *)
let hasThisParam = function
  | THasTyp(UArr(_,_,TTuple(("this",_)::_),_,_,_)) -> true
  | _ -> false


(***** Misc *******************************************************************)

(* the boolean b in binding (x,b) indicates whether x is a reference.
     if so,  [[ x ]] = deref __x
     if not, [[ x ]] = __x
*)
type env = bool IdMap.t

let convertConst = function
  | J.CString(s) -> EVal (VBase (Str s))
  | J.CInt(i)    -> EVal (VBase (Int i))
  | J.CBool(b)   -> EVal (VBase (Bool b))
  | J.CNull      -> EVal (VBase Null)
  | J.CUndefined -> EVal (VBase Undef)
  | J.CNum _     -> failwith "convert CNum"
  | J.CRegexp _  -> failwith "convert CRegexp"

let eLambda xs e =
  let pat = PNode (List.map (fun x -> PLeaf x) xs) in
  ParseUtils.mkPatFun ([],[],[]) pat e

(*
let eSeq e1 e2 =
  ELet (freshVar "seq", None, e1, e2)
*)

let rec eSeq = function
  | []    -> failwith "eSeq: must call with at least one exp"
  | [e]   -> e
  | e::es -> ELet (freshVar "seq", None, e, eSeq es)

let mkArgsArray es = 
  let l = LocConst (freshVar "argsArray") in
  (l, ENewref (l, ParseUtils.mkTupleExp es))

(* normal desugaring creates a local variable "x" for JS formal "x",
   set to the initial value passed in. so that i can still use the JS
   formals inside types, using a different name for the corresponding
   local variable. *)
let dsVar x =
  spr "__%s" x

let undoDsVar x =
  String.sub x 2 (String.length x - 2)


(***** Prop/Bracket ***********************************************************)

(* rkc: hacked LamJS/exprjs_syntax.ml to distinguish between prop/bracket,
   even though the abstract syntax doesn't. so, need to make sure to undo
   the hack whenever using BracketExpr or PropLValue *)

let undoDotStr s =
  if Str.string_match (Str.regexp "^__dot__\\(.*\\)$") s 0
  then (true, Str.matched_group 1 s)
  else (false, s)

let undoDotExp = function
  | E.ConstExpr (p, J.CString s) ->
      E.ConstExpr (p, J.CString (snd (undoDotStr s)))
  | e -> e


(***** Desugaring expressions *************************************************)

let objOp ts ls fn args =
  EApp ((ts,ls,[]), eVar fn, ParseUtils.mkTupleExp args)

let objGet l1 l2 x k      = objOp [] [l1;l2] "objGet" [x; k]
let objSet l1 l2 x k y    = objOp [] [l1;l2] "objSet" [x; k; y]
let objHas l1 l2 x k      = objOp [] [l1;l2] "objHas" [x; k]
let objHasOwn l1 l2 x k   = objOp [] [l1;l2] "objHasOwn" [x; k]

let rec ds env = function

  | E.HintExpr (_, s, E.ConstExpr (_, J.CString "#define")) ->
      if Hashtbl.mem macroDefs s
      then eStr (spr "__ macro %s __" (Hashtbl.find macroDefs s))
      else failwith "ds define: should never happen"

  | E.ConstExpr (_, J.CString(s)) ->
      if Hashtbl.mem macroDefs s
      then eStr (spr "__ macro %s __" (Hashtbl.find macroDefs s))
      else convertConst (J.CString s)

  | E.ConstExpr (_, c) -> convertConst c

  | E.HintExpr (_, h, E.ObjectExpr (p, fields)) when !Settings.fullObjects ->
(*
      let (l1,l2) = parseObjLocs h in
*)
      let l1 = parseLoc h in
      let obj = freshVar "newObj" in
      let setFields =
        List.map
          (fun (_,k,v) -> objSet l1 lObject (eVar obj) (eStr k) (ds env v))
          fields
      in
      ELet (obj, None, ENewObj (EVal VEmpty, l1, eObject, lObject),
            eSeq (setFields @ [eVar obj]))

  | E.ObjectExpr (p, fields) when !Settings.fullObjects ->
      failwith "objlit: need annotation"

  | E.HintExpr (_, h, E.ObjectExpr (p, fields)) -> 
      ENewref (parseLoc h, mkEDict env fields)

  | E.ObjectExpr (p, fields) -> 
      ENewref (LocConst (freshVar "objLit"), mkEDict env fields)

  | E.HintExpr (_, h, E.ArrayExpr (_, es)) when !Settings.fullObjects ->
      let (l,t) = parseArrLit h in
      ENewObj (mkEArray t env es, l, eVar "__ArrayProto", LocConst "lArrayProto")

  | E.ArrayExpr _ when !Settings.fullObjects -> failwith "arrayexpr"

  | E.HintExpr (_, h, E.ArrayExpr (_, es)) ->
      let (l,t) = parseArrLit h in
      ENewref (l, mkEArray t env es)

  | E.ArrayExpr (_, es) ->
      ENewref (LocConst (freshVar "arrLit"), mkEArray tyAny env es)

  | E.ThisExpr p -> 
      (* In JavaScript, 'this' is a reserved word.  Hence, we are certain that
         the the bound identifier is not captured by existing bindings. *)
      if !Settings.fullObjects then eVar "this"
      else printParseErr "\"this\" not allowed in djsLite mode"

  | E.IdExpr (p, x) -> let _ = failwith "rkc: ds idexpr" in EVar x

  | E.VarExpr (p, x) -> begin
      let x = dsVar x in
      (* TODO: IdExpr makes the else clause unnecessary *)
      try 
        if IdMap.find x env then
          (* var-lifting would have introduced a binding for x. *)
          EDeref (EVar x)
        else
          EVar x
      with Not_found ->
        (* TODO *)
        let _ = failwith (spr "rkc: think about top-level VarExpr [%s]" x) in
        mkApp (eVar "get") [EDeref (EVar "global"); eStr x]
    end

(*
  | E.BracketExpr (_, E.HintExpr (_, h, e1), e2) when !Settings.fullObjects ->
      let (l1,l2) = parseObjLocs h in
      objGet l1 l2 (ds env e1) (ds env e2)
*)

  | E.BracketExpr (_, E.HintExpr (_, h, e1), e2) when !Settings.fullObjects ->
    begin
      let (ts,ls,_) = parseAppArgs h in
      (* not doing any type/loc parameter inference prop/elem cases, since
         don't know if e1 is an object or array *)
      match e2 with
        | E.ConstExpr (_, J.CInt i) ->
            let t = match ts with
              | []  -> tyAny
              | [t] -> t
              | _   -> failwith "too many type args to getIdx" in
            let (l1,l2) = match ls with
              | [l1;l2] -> (l1, l2)
              | [l]     -> (l, LocConst "lArrayProto")
              | _       -> failwith "need 1 or 2 loc args for getIdx" in
            objOp [t] [l1;l2] "getIdx" [ds env e1; EVal (vInt i)]
        | E.ConstExpr (_, J.CString s) ->
            let (b,s) = undoDotStr s in
            let f = if b then "getProp" else "getElem" in
            objOp ts ls f [ds env e1; EVal (vStr s)]
        | _ ->
            let e2 = undoDotExp e2 in
            objOp ts ls "getElem" [ds env e1; ds env e2]
    end

  | E.BracketExpr (_, E.HintExpr (_, h, e1), e2) -> begin
      let e2 = undoDotExp e2 in
      let (ts,ls,_) = parseAppArgs h in
      let t = match ts with
        | []  -> tyAny
        | [t] -> t
        | _   -> failwith "too many type args to get prop/elem lite" in
      let l = match ls with
        | [l] -> l
        | _   -> failwith "need exactly one loc arg for get prop/elem lite" in
      match e2 with
        | E.ConstExpr (_, J.CInt i) ->
            objOp [t] [l] "getIdxLite" [ds env e1; EVal (vInt i)]
        | E.ConstExpr (_, J.CString s) ->
            objOp [t] [l] "getPropLite" [ds env e1; EVal (vStr s)]
        | _ ->
            objOp [t] [l] "getElemLite" [ds env e1; ds env e2]
    end

  (* TODO this should be UnsafeGetField. what is difference? *)
  | E.BracketExpr (_, e1, e2) ->
      let e2 = undoDotExp e2 in
      mkApp (eVar "get") [EDeref (ds env e1); ds env e2]

  | E.PrefixExpr (_, "prefix:delete", e) -> begin
      match e with E.BracketExpr (_, ed, ek) -> begin
        if !Settings.fullObjects then
          printParseErr "full: delete"
        else
          let ek = undoDotExp ek in
          let x = freshVar "del" in
          ELet (x, None, ds env ed,
                ESetref (eVar x,
                         mkApp (eVar "del") [EDeref (eVar x); ds env ek]))
      end
      | _ -> printParseErr "delete not applied to property"
    end

  | E.PrefixExpr (_, op, e) ->
      let e0 =
        match op with
          | "prefix:typeof" -> "tagof"
          | "prefix:!"      -> "neg"
          | "prefix:-"      -> "unary_minus"
          | x               -> failwith (spr "Op1Prefix [%s]" x)
      in
      mkApp (eVar e0) [ds env e]

  | E.InfixExpr (_, "in", ek, ed) ->
      if !Settings.fullObjects then begin
        match ed with
          | E.HintExpr (_, s, ed) ->
              let (l1,l2) = parseObjLocs s in
              objHas l1 l2 (ds env ed) (ds env ek)
          | _ -> printParseErr "key membership requires loc annotations"
      end else
        mkApp (eVar "mem") [EDeref (ds env ed); ds env ek]

  | E.InfixExpr (_, op, e1, e2) ->
      let e0 =
        match op with
          | "+"  -> "plus"
          | "-"  -> "minus"
          | "*"  -> "mult"
          | "==" -> "eq"
          (* TODO *)
          | "===" -> "eq"
          | "<=" -> "le"
          | "<"  -> "lt"
          | "&&" -> "l_and"
          | "^"  -> let _ = Log.warn "TODO is ^ op JS? Rhino allows it?" in
                    "strcat"
          | "in" -> "mem"
          | _    -> failwith (spr "Op2Infix [%s]" op)
      in
      mkApp (eVar e0) [ds env e1; ds env e2]

  | E.IfExpr (_, e1, e2, e3) -> 
      EIf (ds env e1, ds env e2, ds env e3)

  | E.AssignExpr (_, E.VarLValue (_, x), e) -> 
      let x = dsVar x in
      if IdMap.mem x env then (* assume var-bound *)
        ESetref (eVar x, ds env e)
      else
        let _ = failwith (spr "assignexpr global [%s]" x) in
        ESetref (eVar "global", mkApp (eVar "set") [EDeref (eVar "global");
                                                    eStr x;
                                                    ds env e])

  | E.AssignExpr (_, E.PropLValue (_, E.HintExpr (_, h, e1), e2), e3)
    when !Settings.fullObjects -> 
      (* TODO dot string *)
      let (l1,l2) = parseObjLocs h in
      objSet l1 l2 (ds env e1) (ds env e2) (ds env e3)

  | E.AssignExpr (_, E.PropLValue (_, E.HintExpr (_, h, e1), e2), e3) -> begin
      let e2 = undoDotExp e2 in
      let (ts,ls,_) = parseAppArgs h in
      let t = match ts with
        | []  -> tyAny
        | [t] -> t
        | _   -> failwith "too many type args to getIdx" in
      let l = match ls with
        | [l] -> l
        | _   -> failwith "need exactly one loc arg for getIdx" in
      match e2 with
        | E.ConstExpr (_, J.CInt i) ->
            objOp [t] [l] "setIdxLite" [ds env e1; EVal (vInt i); ds env e3]
        | E.ConstExpr (_, J.CString s) ->
            objOp [t] [l] "setPropLite" [ds env e1; EVal (vStr s); ds env e3]
        | _ ->
            objOp [t] [l] "setElemLite" [ds env e1; ds env e2; ds env e3]
    end

  | E.AssignExpr (_, E.PropLValue (_, e1, e2), e3) -> 
      let e2 = undoDotExp e2 in
      let x = freshVar "obj" in
      ELet (x, None, ds env e1,
            ESetref (eVar x, mkApp (eVar "set") [EDeref (eVar x);
                                                 ds env e2; 
                                                 ds env e3]))

  | E.LetExpr (_, x, e1, e2) ->
      let x = dsVar x in
      ELet (x, None, ds env e1, ds (IdMap.add x false env) e2)

  (* rkc: catching VarDeclExpr within SeqExpr so i can turn it into a
       normal let-binding instead of doing var lifting or implicit
       updates to global *)

(*
  (* rkc TODO figure out what annotation for x should be *)
  | E.SeqExpr (_, E.HintExpr (_, s, E.VarDeclExpr (p1, x, xInit)), e) ->
    begin
      (match xInit with
         | E.ConstExpr (_, J.CUndefined) -> ()
         | _ -> printParseErr "EJS should've set HintVarDecl init to undef"
      );
      failwith "hint var"
    end
*)

  | E.SeqExpr (_, E.VarDeclExpr (_, x, e), e2) -> begin
      let (lo,e) =
        match e with
          | E.HintExpr (_, s, (E.ConstExpr (_, J.CUndefined) as eUndef)) ->
               (Some (parseLoc s), eUndef)
          | _ ->
               (None, e) in

      if IdMap.mem x env then (* x is local variable *)
        (if !Settings.doVarLifting (* do what LamJS normally does *)
         then eSeq [dsVarDeclOrig env x e; ds env e2]
         else dsVarDecl env x lo e e2)

      else (* x is declared at the top-level scope *)
        (if !Settings.doImplicitGlobal (* do what LamJS normally does *)
         then eSeq [dsVarDeclOrig env x e; ds env e2]
         else dsVarDecl env x lo e e2)
    end

  | E.SeqExpr (_, E.HintExpr (_, s, E.FuncStmtExpr (p, f, args, body)), e2)
    when !Settings.fullObjects ->
      let fOrig = f in
      let f = dsVar f in
      let code =
        EAs ("DjsDesugarCtor",
             dsFunc true env p args body,
             s |> desugarCtorHint |> ParseUtils.typToFrame) in
      let proto =
        ENewObj (EVal VEmpty, LocConst (spr "&%s_proto" fOrig),
                 eObject, lObject) in
      let obj =
        ENewref (LocConst (spr "&%s_obj" fOrig),
                 EDict [(eStr "code", code);
                        (eStr "prototype", proto)]) in
      (* adding f to after dsFunc, since ctor shouldn't be recursive *)
      let env = IdMap.add f true env in
      ELet (f, None, ENewref (LocConst (spr "&%s" fOrig), obj), ds env e2)

  (* rkc: turning this into a letrec *)
  | E.SeqExpr (_, E.HintExpr (_, s, E.FuncStmtExpr (p, f, args, body)), e2) ->
    begin
      printParseErr "djsDesugar 11/27: letrec"
(*
      let (scm,wrapE) = desugarHint s in
      let env = IdMap.add f false env in
      (* TODO is this right place to wrap? try polymorphic rec fun. *)
      let e1 = wrapE (dsFunc env p args body) in
      let e2 = ds env e2 in
      ParseUtils.mkLetRec f scm e1 e2
*)
    end

  (* rkc: the original LamJS case *)
  | E.SeqExpr (_, e1, e2) -> 
      eSeq [ds env e1; ds env e2]

  | E.HintExpr (_, s, E.LabelledExpr (_, bl, E.WhileExpr (_, test, e2)))
      when isBreakLabel bl ->
    begin
      let (h1,t2,h2) = parseWhile s in
      match e2 with
        | E.LabelledExpr(_,cl,body) when isContLabel cl ->
            dsWhile env bl cl test body (h1,t2,h2)
        | E.SeqExpr(_,E.LabelledExpr(_,cl,body),incr) when isContLabel cl ->
            dsFor env bl cl test body incr (h1,t2,h2)
        | _ ->
            printParseErr "desugar EJS while fail"
    end

  | E.HintExpr (_, s, E.LabelledExpr (_, bl, E.DoWhileExpr (_, e1, test)))
      when isBreakLabel bl ->
    begin
      let (h1,t2,h2) = parseWhile s in
      match e1 with
        | E.LabelledExpr(_,cl,body) when isBreakLabel cl ->
            dsDoWhile env bl cl test body (h1,t2,h2)
        | _ ->
            printParseErr "desugar annotated do/while fail"
    end

  | E.LabelledExpr (_, bl, E.WhileExpr (_, test, e2)) when isBreakLabel bl ->
    begin
      failwith "djsDesugar 11/27: loop"
(*
      match e2 with
        | E.LabelledExpr (_, cl, body) when isContLabel cl ->
            dsWhile env bl cl test body ([],tyAny,[])
        | E.SeqExpr (_, E.LabelledExpr (_, cl, body), incr) when isContLabel cl ->
            dsFor env bl cl test body incr ([],tyAny,[])
        | _ ->
            printParseErr "EJS always wraps while body with continue"
*)
    end

(*
  | E.LabelledExpr (_, "%break", E.WhileExpr (_, e1, e2)) ->
      dsWhile true env e1 e2 ([],tyAny,[])

  | E.HintExpr (_, s, E.LabelledExpr (_, "%break", E.DoWhileExpr (_, e1, e2))) ->
      let (h1,t2,h2) = parseWhile s in
      dsWhile false env e2 e1 (h1,t2,h2)
*)

  | E.LabelledExpr (_, bl, E.DoWhileExpr (_, e1, test)) when isBreakLabel bl ->
    begin
      failwith "djsDesugar 11/27: loop 2"
(*
      match e1 with
        | E.LabelledExpr(_,cl,body) when isContLabel cl ->
            dsDoWhile env bl cl test body ([],tyAny,[])
        | _ ->
            printParseErr "desugar unannotated do/while fail"
*)
    end

  | E.WhileExpr _
  | E.DoWhileExpr _ ->
      printParseErr "EJS always wraps while and do/while with %break label"

(*
  | ForInExpr (p, x, obj, body) ->
      EFix
        (p,
         [ ("%forin",
            ELambda 
              (p, [x],
               (* TODO: Infinite loop below, but adequate for typing *)
               ESeq (p, ds_expr env body,
                     EApp (p, EId (p, "%forin"), [])))) ],
         EApp (p, EId (p, "%forin"), []))

*)

  (* rkc: fall through to original Lam JS case *)
  | E.LabelledExpr (_, l, e) -> ELabel (trimLabel l, None, ds env e)

  | E.BreakExpr (_, l, e) -> EBreak (trimLabel l, ds env e)

(*
  | TryCatchExpr (p, body, x, catch) ->
      ETryCatch (p, ds_expr env body, ELambda (p, [x], ds_expr env catch))
  | TryFinallyExpr (p, e1, e2) -> 
      ETryFinally (p, ds_expr env e1, ds_expr env e2)
  | ThrowExpr (p, e) -> EThrow (p, ds_expr env e)
  | AppExpr (p, BracketExpr (p', obj, prop), args) ->
      ELet (p, "%obj", ds_expr env obj,
            EApp (p, EOp2 (p', UnsafeGetField,
                           EOp1 (p', Deref, EId (p, "%obj")),
                                ds_expr env prop),
                  [ EId (p, "%obj"); 
                    mk_array (p, map (ds_expr env) args) ]))
*)

  | E.AppExpr (p, E.HintExpr (_, s, E.BracketExpr (p', obj, prop)), args)
    when !Settings.fullObjects ->
      let (ts,ls,hs) = parseAppArgs s in
      let (l1,l2) =
        match ls with
          | l1::l2::_ -> (l1, l2)
          | _ -> printParseErr "ds method call: requires >=2 loc args"
      in
      let obj = ds env obj in
      let (locArgs,argsArray) = mkArgsArray (List.map (ds env) args) in
      let func = objGet l1 l2 obj (ds env prop) in
      EApp ((ts, ls @ [locArgs], hs), func, 
            ParseUtils.mkTupleExp [obj; argsArray])

  | E.AppExpr (p, E.BracketExpr (p', obj, prop), args) ->
      if !Settings.fullObjects
      then printParseErr "method call must be annotated"
      else printParseErr "method call not allowed in djsLite mode"

  | E.AppExpr (p, f, args) ->
      let (f,(ts,ls,hs)) =
        match f with
          | E.HintExpr(_,h,f) -> (f, parseAppArgs h)
          | _                 -> (f, ([],[],[])) in
      let (locArgs,argsArray) = mkArgsArray (List.map (ds env) args) in
      EApp ((ts, ls @ [(*"locGlobal";*) locArgs], hs),
            ds env f,
            ParseUtils.mkTupleExp [(*eVar "global";*) argsArray])

(*
  | E.HintExpr (_, s1, E.NewExpr (_, E.HintExpr (_, s2, constr), args)) -> begin
      if !Settings.fullObjects = false then
        printParseErr "new not allowed in djsLite mode";
      let funcObj = ds env constr in
      let ctor = mkApp (eVar "get") [EDeref funcObj; EVal (vStr "code")] in
      (* TODO need exp/typing rule for newobj to check that proto link is
         indeed the right one
      let proto = mkApp funcObj_ [EVal (vStr "prototype")] in
      *)
      let lObj = parseLoc s1 in
      let (ts,ls,hs) = parseAppArgs s2 in
      let obj = ENewObj (lObj, LocConst "&Fo_proto") in
      let (locArgs,argsArray) = mkArgsArray (List.map (ds env) args) in
      EApp ((ts, ls @ [locArgs], hs), ctor,
            ParseUtils.mkTupleExp [obj; argsArray])
    end
*)

  | E.NewExpr (_, E.HintExpr (_, s, constr), args)-> begin
      if !Settings.fullObjects = false then
        printParseErr "new not allowed in djsLite mode";
      (* could save a couple let-bindings by factoring get (!funcObj) *)
      let funcObj = ds env constr in
      let ctor = mkApp (eVar "get") [EDeref funcObj; eStr "code"] in
      let proto = mkApp (eVar "get") [EDeref funcObj; eStr "prototype"] in
      let ((ts,ls,hs),lProto) = parseNew s in
      let lObj =
        match ls with
          | lObj::_ -> lObj
          | _ -> printParseErr "new annot: must have at least 1 loc arg"
      in
      let obj = ENewObj (EVal VEmpty, lObj, proto, lProto) in
      let (locArgs,argsArray) = mkArgsArray (List.map (ds env) args) in
      EApp ((ts, ls @ [locArgs], hs), ctor,
            ParseUtils.mkTupleExp [obj; argsArray])
    end

  | E.NewExpr _ ->
      if !Settings.fullObjects
      then printParseErr "new must have annotations"
      else printParseErr "new not allowed in djsLite mode"

(*
  | NewExpr (p, constr, args) -> (* TODO: FIX THIS AND APP *)
      ELet (p, "%constr", ds_expr env constr,
            EApp (p, EId (p, "%constr"),
                  [ EObject (p, [ (p, "__proto__", 
                                   EOp2 (p, UnsafeGetField,
                                         EOp1 (p, Deref, EId (p, "%constr")),
                                         EConst (p, JavaScript_syntax.CString "prototype"))) ]);
                    mk_array (p, map (ds_expr env) args) ]))
*)

  (* rkc: LamJS desugaring normally writes to a non-existent reference *)
  (* | FuncStmtExpr (p, f, args, body) -> *)
  (*    EOp2 (p, SetRef, EId (p, f), ds_expr env (FuncExpr (p, args, body))) *)

  (* rkc: LamJS desugaring normally discards hints *)
  (* | HintExpr (_, _, e) -> ds_expr env e *)

  | E.FuncExpr (_, args, _) ->
      printParseErr (spr "function expression with formals [%s] not annotated"
        (String.concat ", " args))

  | E.FuncStmtExpr (_, f, _, _) ->
      printParseErr (spr "function statement [%s] not annotated" f)

  | E.HintExpr (_, s, e) ->
      let t = desugarTypHint s in
      let frame = ParseUtils.typToFrame t in
      let e =
        match e with
          | E.FuncExpr(p,args,body) -> dsFunc (hasThisParam t) env p args body
          | _ -> ds env e
      in
      EAs ("DjsDesugar", e, frame)
(*
      let x = freshVar "hint" in
      ELet (x, Some frame, e, eVar x)
*)

  | E.ThrowExpr _ -> failwith "throwexpr"
  | E.TryFinallyExpr _ -> failwith "try finally"
  | E.TryCatchExpr _ -> failwith "try catch"
  | E.ForInExpr _ -> failwith "forin"

  | E.VarDeclExpr _ -> failwith "ds vardecl: shouldn't get here"

and mkEDict env fields =
  EDict (List.map (fun (_, x, e) -> (eStr x, ds env e)) fields)

and mkEArray t env es =
  EArray (t, List.map (ds env) es)

(* rkc: based on LamJS E.FuncExpr case *)
and dsFunc isCtor env p args body =
  let args = List.map dsVar args in
  let init_var x exp =
(*
    failwith "init_var: what is this?";
*)
    ELet (x, None, ENewref (LocConst (freshVar "freshLoc"), EVal vUndef), exp)
  and get_arg x n exp =
    (*
    ELet (x, None,
          (* ENewref (freshVar "freshLoc", *)
          ENewref (LocConst (spr "&%s" x),
                   mkApp (eVar "get")
                      [EDeref (eVar "arguments");
                       EVal (vStr (string_of_int n))]),
          exp) 
    *)
    (* 11/28: manually doing ANF here so can play the trick with the
       original source binder x, using it as the initial value for the
       pointer variable __x. *)
    let xOrig = undoDsVar x in
    ELet (xOrig, None, mkApp (eVar "getarg") [eStr (string_of_int n)], 
    ELet (x, None, ENewref (LocConst (spr "&%s" xOrig), eVar xOrig),
      exp))
  and vars = Exprjs_syntax.locals body in
  (* rkc: adding locals at top of function body only if flag set *)
  (* let env = IdSet.fold (fun x env -> IdMap.add x true env) vars env in *)
  let env =
    if !Settings.doVarLifting
      then IdSet.fold (fun x env -> IdMap.add x true env) vars env
      else env in
  let env = List.fold_left (fun env x -> IdMap.add x true env) env args in
  let env = IdMap.add "arguments" false (IdMap.add "this" false env) in
  let body = 
    List.fold_right2 get_arg args (Prelude.iota (List.length args))
      (List.fold_right init_var (IdSetExt.to_list vars)
         (ds env body)) in
  (* 11/28: adding "getarg" at the top just once so each get_arg can use it *)
  let body =
    if List.length args = 0 then body
    else ELet ("getarg", None,
               mkApp (eVar "get") [EDeref (eVar "arguments")],
               body)
  in
  if isCtor
    then eLambda ["this"; "arguments"] body
    else eLambda ["arguments"] body

(* rkc: based on LamJS E.WhileExpr case *)
and dsWhile env breakL continueL test body (h1,t2,h2) =
  printParseErr "dsWhile"
(*
  let f = freshVar "while" in
  let loop () = mkApp (eVar f) [EVal vUndef] in
  let u = ([], freshVar "dummy", tyAny, h1, t2, h2) in
  let body =
    if StrSet.mem continueL !jumpedTo
    then let _ = printParseErr "dsWhile continue" in
         ELabel (continueL, Some (AFrame (h1, (STyp tyAny, h1))), ds env body)
    else ds env body in
  let fixloop =
    ParseUtils.mkLetRecMono f u
      (EIf (ds env test, eSeq body (loop ()), EVal vUndef))
      (loop ()) in
  if StrSet.mem breakL !jumpedTo
  then ELabel (breakL, Some (AFrame (h1, (STyp t2, h2))), fixloop)
  else fixloop
*)

(* rkc: based on LamJS E.DoWhileExpr case *)
and dsDoWhile env breakL continueL test body (h1,t2,h2) =
  failwith "dsDoWhile"
(*
  let f = freshVar "dowhile" in
  let loop () = mkApp (eVar f) [EVal vUndef] in
  let u = ([], freshVar "dummy", tyAny, h1, t2, h2) in
  let body =
    if StrSet.mem continueL !jumpedTo
    then let _ = printParseErr "dsDoWhile continue" in
         ELabel (continueL, Some (AFrame (h1, (STyp tyAny, h1))), ds env body)
    else ds env body in
  let fixloop =
    ParseUtils.mkLetRecMono f u
      (eSeq body (EIf (ds env test, loop (), EVal vUndef)))
      (loop ()) in
  if StrSet.mem breakL !jumpedTo
  then ELabel (breakL, Some (AFrame (h1, (STyp t2, h2))), fixloop)
  else fixloop
*)

(* rkc: based on EJS case for J.ForStmt
     note that by this time, the init statement has been de-coupled from
     the rest of the for statement. see notes on desugaring.
*)
and dsFor env breakL continueL test body incr (h1,t2,h2) =
  failwith "dsFor"
(*
  let f = freshVar "forwhile" in
  let loop () = mkApp (eVar f) [EVal vUndef] in
  let u = ([], freshVar "dummy", tyAny, h1, t2, h2) in
  let body =
    if StrSet.mem continueL !jumpedTo
    then let _ = failwith "dsFor continue" in
         ELabel (continueL, Some (AFrame (h1, (STyp tyAny, h1))), ds env body)
    else ds env body in
  let fixloop =
    ParseUtils.mkLetRecMono f u
      (EIf (ds env test,
            eSeq (eSeq body (ds env incr)) (loop ()),
            EVal vUndef))
      (loop ()) in
  if StrSet.mem breakL !jumpedTo
  then ELabel (breakL, Some (AFrame (h1, (STyp t2, h2))), fixloop)
  else fixloop
*)

(* rkc: creates a traditional lexically-scoped let-binding to a reference *)
and dsVarDecl env x lo e e2 =
  (* let l = match lo with Some(l) -> l | None -> freshVar x in *)
  let l = match lo with Some(l) -> l | None -> LocConst (spr "&%s" x) in
  let x = dsVar x in
  ELet (x, None,
        ENewref (l, ds env e),
        ds (IdMap.add x true env) e2)

  (* could even forgo the ref if a reason should arise ... *)
  (* ELet (x, None, None,
            ds env e,
            ds (IdMap.add x false env) e2) *)

and dsVarDeclOrig env x e =
  printParseErr (spr "dsVarDeclOrig [%s]" x)
(*
  (* rkc: this is the original LamJS case. *)
  | VarDeclExpr (p, x, e) -> 
      let _ = failwith "rkc: original VarDeclExpr case called" in
      if IdMap.mem x env then
        (* var-lifting would have introduced a binding for x. *)
        EOp2 (p, SetRef, EId (p, x), ds_expr env e)
      else 
        let _ = failwith "rkc: think about top-level VarDecl" in
        EOp2 (p, SetRef, EId (p, "[[global]]"),
              EUpdateField (p, EOp1 (p, Deref, EId (p, "[[global]]")),
                            EConst (p, JavaScript_syntax.CString x),
                            ds_expr env e))
*)

let desugar e =
  checkVars e;
  let e = freshenLabels e in
  collectMacros e;
  ds Prelude.IdMap.empty e

