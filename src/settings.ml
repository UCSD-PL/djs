
let djs_dir =
  try
    let s = Unix.getenv "DJS_DIR" in
    if s.[String.length s - 1] = '/' then s
    else s ^ "/" (* ensuring trailing '/' *)
  with Not_found ->
    Lang.kill "Set and export the environment variable DJS_DIR \
               to the root of the DJS directory"

let out_dir  = djs_dir ^ "src/out/"
let prim_dir = djs_dir ^ "prims/"

let parseOnly = ref false
let strictWarn = ref true
let printAllTypes = ref false
let printShortQuick = ref true
let doFalseChecks = ref false
let quickTypes = ref true
let checkWfSynthesis = ref true
let tryAllBoxesHack = ref false

(* DJS options *)
let djsMode = ref false
let augmentHeaps = ref true
