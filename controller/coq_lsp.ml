(************************************************************************)
(*         *   The Coq Proof Assistant / The Coq Development Team       *)
(*  v      *   INRIA, CNRS and contributors - Copyright 1999-2018       *)
(* <O___,, *       (see CREDITS file for the list of authors)           *)
(*   \VV/  **************************************************************)
(*    //   *    This file is distributed under the terms of the         *)
(*         *     GNU Lesser General Public License Version 2.1          *)
(*         *     (see LICENSE file for the text of the license)         *)
(************************************************************************)

(************************************************************************)
(* Coq Language Server Protocol                                         *)
(* Copyright 2019 MINES ParisTech -- Dual License LGPL 2.1 / GPL3+      *)
(* Copyright 2019-2023 Inria      -- Dual License LGPL 2.1 / GPL3+      *)
(* Written by: Emilio J. Gallego Arias                                  *)
(************************************************************************)

(* This is the native-specific Code for the implementation of the event queue
   based in OCaml threads. *)

module U = Yojson.Safe.Util
module LIO = Lsp.Io
module LSP = Lsp.Base
open Controller
open Lsp_core

(* Do cleanup here if necessary *)
let exit_message () =
  let message = "server exiting" in
  LIO.logMessage ~lvl:Error ~message

let lsp_cleanup () = exit_message ()

let rec process_queue ~delay ~io ~ofn ~state : unit =
  if Fleche.Debug.sched_wakeup then
    LIO.trace "<- dequeue" (Format.asprintf "%.2f" (Unix.gettimeofday ()));
  match dispatch_or_resume_check ~io ~ofn ~state with
  | None ->
    (* As of now, we exit the whole program here, we could try an experiment to
       invert the threads, so the I/O routine is a thread and process_queue is
       the main driver *)
    lsp_cleanup ();
    (* We can't use [Thread.exit] here as the main thread will be blocked on
       I/O *)
    exit 0
  | Some (Yield state) ->
    Thread.delay delay;
    process_queue ~delay ~io ~ofn ~state
  | Some (Cont state) -> process_queue ~delay ~io ~ofn ~state

let concise_cb ofn =
  let send_notification nt =
    Lsp.Base.Message.(Notification nt |> to_yojson) |> ofn
  in
  let diagnostics ~uri ~version diags =
    if List.length diags > 0 then
      Lsp.JLang.mk_diagnostics ~uri ~version diags |> send_notification
  in
  Fleche.Io.CallBack.
    { trace = (fun _hdr ?extra:_ _msg -> ())
    ; message = (fun ~lvl:_ ~message:_ -> ())
    ; diagnostics
    ; fileProgress = (fun ~uri:_ ~version:_ _progress -> ())
    ; perfData = (fun ~uri:_ ~version:_ _perf -> ())
    ; serverVersion = (fun _ -> ())
    ; serverStatus = (fun _ -> ())
    }

(* Main loop *)
let lsp_cb ofn =
  let send_notification nt =
    Lsp.Base.Message.(Notification nt |> to_yojson) |> ofn
  in
  let trace = LIO.trace in
  let message ~lvl ~message =
    let lvl = Fleche.Io.Level.to_int lvl in
    LIO.logMessageInt ~lvl ~message
  in
  let diagnostics ~uri ~version diags =
    Lsp.JLang.mk_diagnostics ~uri ~version diags |> send_notification
  in
  let fileProgress ~uri ~version progress =
    Lsp.JFleche.mk_progress ~uri ~version progress |> send_notification
  in
  let perfData ~uri ~version perf =
    Lsp.JFleche.mk_perf ~uri ~version perf |> send_notification
  in
  let serverVersion vi = Lsp.JFleche.mk_serverVersion vi |> send_notification in
  let serverStatus st = Lsp.JFleche.mk_serverStatus st |> send_notification in
  Fleche.Io.CallBack.
    { trace
    ; message
    ; diagnostics
    ; fileProgress
    ; perfData
    ; serverVersion
    ; serverStatus
    }

let coq_init ~debug =
  let load_module = Dynlink.loadfile in
  let load_plugin = Coq.Loader.plugin_handler None in
  Coq.Init.(coq_init { debug; load_module; load_plugin })

let exit_notification =
  Lsp.Base.Message.(Notification { method_ = "exit"; params = [] })

let rec lsp_init_loop ~ifn ~ofn ~cmdline ~debug =
  match ifn () with
  | None -> raise Lsp_exit
  | Some (Ok msg) -> (
    match lsp_init_process ~ofn ~cmdline ~debug msg with
    | Init_effect.Exit -> raise Lsp_exit
    | Init_effect.Loop -> lsp_init_loop ~ifn ~ofn ~cmdline ~debug
    | Init_effect.Success w -> w)
  | Some (Error err) ->
    Lsp.Io.trace "read_request" ("error: " ^ err);
    lsp_init_loop ~ifn ~ofn ~cmdline ~debug

let lsp_main bt coqcorelib coqlib ocamlpath vo_load_path ml_include_path
    require_libraries delay int_backend =
  Coq.Limits.select_best int_backend;
  Coq.Limits.start ();

  (* Try to be sane w.r.t. \r\n in Windows *)
  Stdlib.set_binary_mode_in stdin true;
  Stdlib.set_binary_mode_out stdout true;

  (* We output to stdout *)
  let ifn () = LIO.read_message stdin in

  (* Set log channels *)
  let json_fn = LIO.send_json Format.std_formatter in

  let ofn response =
    let response = Lsp.Base.Message.to_yojson response in
    LIO.send_json Format.std_formatter response
  in

  LIO.set_log_fn json_fn;

  let io = lsp_cb json_fn in
  Fleche.Io.CallBack.set io;

  (* IMPORTANT: LSP spec forbids any message from server to client before
     initialize is received *)

  (* Core Coq initialization *)
  let debug = bt || Fleche.Debug.backtraces in
  let root_state = coq_init ~debug in
  let cmdline =
    { Coq.Workspace.CmdLine.coqcorelib
    ; coqlib
    ; ocamlpath
    ; vo_load_path
    ; ml_include_path
    ; args = []
    ; require_libraries
    }
  in

  (* Read JSON-RPC messages and push them to the queue *)
  let rec read_loop () =
    match ifn () with
    | None ->
      (* EOF, push an exit notication to the queue *)
      enqueue_message exit_notification
    | Some (Ok msg) ->
      enqueue_message msg;
      read_loop ()
    | Some (Error err) ->
      Lsp.Io.trace "read_request" ("error: " ^ err);
      read_loop ()
  in

  (* Input/output will happen now *)
  try
    (* LSP Server server initialization *)
    let workspaces = lsp_init_loop ~ifn ~ofn ~cmdline ~debug in
    let io =
      if !Fleche.Config.v.verbosity < 2 then (
        Fleche.Config.(
          v := { !v with send_diags = false; send_perf_data = false });
        LIO.set_log_fn (fun _obj -> ());
        let io = concise_cb json_fn in
        Fleche.Io.CallBack.set io;
        io)
      else io
    in

    (* Core LSP loop context *)
    let default_workspace = Coq.Workspace.default ~debug ~cmdline in
    let state = { State.root_state; cmdline; workspaces; default_workspace } in

    (* Read workspace state (noop for now) *)
    Cache.read_from_disk ();

    let pfn () : unit = process_queue ~delay ~io ~ofn ~state in
    let (_ : Thread.t) = Thread.create pfn () in

    read_loop ()
  with
  | Lsp_exit ->
    let message = "[LSP shutdown] EOF\n" in
    LIO.logMessage ~lvl:Error ~message
  | exn ->
    let bt = Printexc.get_backtrace () in
    let exn, info = Exninfo.capture exn in
    let exn_msg = Printexc.to_string exn in
    LIO.trace "fatal error" (exn_msg ^ bt);
    LIO.trace "fatal_error [coq iprint]"
      Pp.(string_of_ppcmds CErrors.(iprint (exn, info)));
    LIO.trace "server crash" (exn_msg ^ bt);
    let message = "[uncontrolled LSP shutdown] server crash\n" ^ exn_msg in
    LIO.logMessage ~lvl:Error ~message

(* Arguments handling *)
open Cmdliner

let delay : float Term.t =
  let doc = "Delay value in seconds when server is idle" in
  Arg.(value & opt float 0.1 & info [ "D"; "idle-delay" ] ~docv:"DELAY" ~doc)

let term_append l =
  Term.(List.(fold_right (fun t l -> const append $ t $ l) l (const [])))

let lsp_cmd : unit Cmd.t =
  let doc = "Coq LSP Server" in
  let man =
    [ `S "DESCRIPTION"
    ; `P "Coq LSP server"
    ; `S "USAGE"
    ; `P "See the documentation on the project's webpage for more information"
    ]
  in
  let open Coq.Args in
  let vo_load_path = term_append [ rload_paths; qload_paths ] in
  Cmd.(
    v
      (Cmd.info "coq-lsp" ~version:Fleche.Version.server ~doc ~man)
      Term.(
        const lsp_main $ bt $ coqcorelib $ coqlib $ ocamlpath $ vo_load_path
        $ ml_include_path $ ri_from $ delay $ int_backend))

let main () =
  let ecode = Cmd.eval lsp_cmd in
  exit ecode

let () = main ()
