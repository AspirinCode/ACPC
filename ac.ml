
open Batteries
open Printf

module A    = Array
module AC   = Autocorr
module S    = String
module F    = File
module Fn   = Filename
module HT   = Hashtbl
module L    = List
module Log  = Log
module MU   = My_utils
module Mol2 = Mol2_parser
module V3   = Vector3

(* to factorize code *)
let list_parmap ncores f l =
  Parmap.parmap ~ncores f (Parmap.L l)

(* to factorize code *)
let list_pariter ncores f l =
  Parmap.pariter ~ncores f (Parmap.L l)

type comparison = CC | Tani | Tref | Tdb

let comparison_of_string = function
  | "CC"   -> CC
  | "Tani" -> Tani
  | "Tref" -> Tref
  | "Tdb"  -> Tdb
  | s -> failwith ("ac.ml: unknown comparison method: " ^ s)

let string_of_comparison = function
  | CC   -> "CC"
  | Tani -> "Tani"
  | Tref -> "Tref"
  | Tdb  -> "Tdb"

let fun_of_comparison = function
  | CC   -> AC.correlate_linbin_autocorrs
  | Tani -> AC.tanimoto_linbin_autocorrs
  | Tref -> AC.tversky_ref_linbin_autocorrs
  | Tdb  -> AC.tversky_db_linbin_autocorrs

let do_query
    comparison
    verbose
    query_file
    dx
    nprocs
    db_kdes
    post_filter
    db_file
    do_plot
    do_ROC
    list_htq
    top_n
    out_fn =
  let cmp_fun = fun_of_comparison    comparison in
  let cmp_str = string_of_comparison comparison in
  let query_basename = Fn.chop_extension query_file in
  let roc_data   = query_basename ^ ".scored-label"  in
  let ranks_data = query_basename ^ ".ranks"         in
  let auc_data   = query_basename ^ ".auc"           in
  let roc_curve  = query_basename ^ ".roc"           in
  let roc_plot   = query_basename ^ ".gpl"           in
  let debug_prefix_fn =
    if verbose
    then Some query_basename
    else None
  in
  let unused_molecule_index = -1 in
  let query_desc =
    let query = Mol2.read_molecules query_file in
    match query with
      | []  -> failwith ("no molecule in query file: " ^ query_file)
      | [q] -> let query_name, query_ac =
                 Kde.linbin_autocorr debug_prefix_fn dx q
               in
               (unused_molecule_index, query_name, query_ac)
      | queries ->
        let _ = Log.fatal "more than one molecule in %s" query_file in
        exit 1
  in
  let dup_scores = (* may contain duplicate molecules (diff. comformers of
                      a same molecule) *)
    (if nprocs > 1 then list_parmap nprocs else L.map)
      (fun ((i, name, _ac) as candidate) ->
         let score = cmp_fun query_desc candidate in
         (i, name, score)
      )
      db_kdes
  in
  let scores =
    if post_filter then
      ROC.unique dup_scores
    else
      let _ = Log.warn "not removing duplicate molecules" in
      dup_scores
  in
  let maybe_list_htq =
    if list_htq then Some (cmp_fun query_desc query_desc)
    else None
  in
  let top_n_molecules =
    ROC.dump_ranks ranks_data scores maybe_list_htq top_n
  in
  let auc =
    if do_ROC then begin
      ROC.dump_scored_labels roc_data scores;
      ROC.read_AUC_from_string
        (MU.get_command_output
           (sprintf "croc-curve < %s 1> %s 2> %s; cat %s"
              roc_data roc_curve auc_data auc_data))
    end else
      nan
  in
  if top_n <> 0 && out_fn <> "" then (
    Log.info "outputting top %d molecules in %s..." top_n out_fn;
    (* put all molecules in a table *)
    let indexed_molecules = Mol2.read_raw_molecules db_file in
    (* output top N best ones *)
    F.with_file_out out_fn (fun out ->
      L.iter
        (fun (i, _name, _score) ->
           let molecule_lines = indexed_molecules.(i) in
           L.iter (fprintf out "%s\n") molecule_lines
        )
        top_n_molecules
    );
  );
  if do_ROC && do_plot then (
    MU.string_list_to_file roc_plot
      [sprintf
          "set title \"%s\\ncmp: %s dx: %.4f AUC: %.3f\""
          query_file cmp_str dx auc;
       "set size square";
       "set xlabel 'FPR'";
       "set ylabel 'TPR'";
       "set key bottom";
       "f(x) = x";
       sprintf "plot '%s' u 1:2 w lines notitle, \
                      f(x)      w lines notitle" roc_curve]
  );
  Log.info
    "db: %s q: %s cmp: %s dx: %f AUC: %.3f"
      db_file query_file cmp_str dx auc;
  if do_ROC && do_plot then MU.run_command ("gnuplot -persist " ^ roc_plot)

let main () =
  let start = Unix.gettimeofday() in
  Log.set_log_level Log.INFO;
  Log.color_on();
  Log.info "\n\nCopyright (C) 2014, Zhang Initiative Research Unit,\n\
            Institute Laboratories, RIKEN\n\
            2-1 Hirosawa, Wako, Saitama 351-0198, Japan\n";
  (* default option values *)
  let cmp_method  = ref "CC"  in
  let query_file  = ref ""    in
  let query_files = ref ""    in
  let db_file     = ref ""    in
  let out_file    = ref ""    in
  let dx          = ref 0.005 in
  let debug       = ref false in
  let post_filter = ref true  in
  let nprocs      = ref 1     in
  let top_n       = ref 0     in
  let do_plot     = ref true  in
  let do_ROC      = ref true  in
  let list_htq    = ref false in
  let cmd_line = Arg.align [
    "-cmp" , Arg.Set_string cmp_method ,
    sprintf "{CC|Tani|Tref|Tdb} LBAC+/- comparison method (default: %s)"
      !cmp_method;
    "-htq" , Arg.Set list_htq          ,
    " list molecules scoring Higher Than the Query with itself";
    "-q"   , Arg.Set_string query_file , "query.mol2 query (incompatible \
                                          with -qf)";
    "-qf"  , Arg.Set_string query_files, "f file containing a list of mol2 \
                                          files (incompatible with -q)";
    "-db"  , Arg.Set_string db_file   , "db.mol2 database";
    "-dx"  , Arg.Set_float dx         ,
    (sprintf "float X axis discretization (default: %f)" !dx);
    "-v"   , Arg.Set debug            , " output intermediate results";
    "-nopp", Arg.Clear post_filter    , " don't rm duplicate molecules";
    "-np"  , Arg.Set_int nprocs       ,
    sprintf "nprocs max CPUs to use (default: %d)"
      !nprocs;
    "-ng"  , Arg.Clear do_plot        , " no gnuplot";
    "-nr"  , Arg.Clear do_ROC         , " no ROC curve (also sets -ng)";
    "-o"   , Arg.Set_string out_file  ,
    "output.mol2 output file (also requires -top, incompatible with -qf)";
    "-top" , Arg.Set_int top_n        ,
    "N nb. best scoring molecules to output (also requires -o)";
  ] in
  Arg.parse cmd_line ignore
    (sprintf "Example: %s -q query.mol2 -db database.mol2\n" Sys.argv.(0));
  if !query_file <> "" && !query_files <> "" then begin
    Log.fatal "use either -q or -qf, not both";
    exit 1
  end;
  let cmp_f = comparison_of_string !cmp_method in
  let db_molecules = Mol2.read_molecules !db_file in
  let nb_molecules_in_db = float_of_int (L.length db_molecules) in
  let db_kdes =
    let i = ref 0 in
    (if !nprocs > 1 then list_parmap !nprocs else L.map)
      (fun m ->
        let name, ac = Kde.linbin_autocorr None !dx m in
        let j = !i in
        incr i;
        (j, name, ac))
      db_molecules
  in
  let nb_queries =
    if !query_file <> "" then
      let _ =
        do_query
          cmp_f
          !debug
          !query_file
          !dx
          !nprocs
          db_kdes
          !post_filter
          !db_file
          !do_plot
          !do_ROC
          !list_htq
          !top_n
          !out_file
      in 1
    else
      let queries = MU.string_list_of_file !query_files in
      (if !nprocs > 1 then list_pariter !nprocs else L.iter)
        (fun q ->
          do_query cmp_f !debug
            q !dx !nprocs db_kdes !post_filter !db_file
            !do_plot !do_ROC !list_htq 0 ""
        )
        queries;
      L.length queries
  in
  let stop = Unix.gettimeofday() in
  let elapsed = stop -. start in
  Log.info
    "speed: %.2f molecules/s"
    ((float_of_int nb_queries) *. nb_molecules_in_db /. elapsed);
;;

main()
