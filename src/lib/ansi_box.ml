open! Import
open ANSITerminal

external sigwinch : unit -> int option = "ocaml_sigwinch"

let sigwinch = sigwinch ()

(** Write to a [ref] before calling [f] and restore its previous value after. *)
let with_ref_set ref value f =
  let old_value = !ref in
  ref := value;
  Fun.protect ~finally:(fun () -> ref := old_value) f

let read_and_print ~log_height ic ic_err (out_init, out_acc, out_finish) =
  let out_acc_err acc l = l :: acc in
  let ic = Lwt_io.of_unix_fd (Unix.descr_of_in_channel ic) ~mode:Lwt_io.input
  and ic_err =
    Lwt_io.of_unix_fd (Unix.descr_of_in_channel ic_err) ~mode:Lwt_io.input
  in
  let isatty = Unix.isatty Unix.stdout in
  let terminal_size = ref (if isatty then fst @@ size () else 0) in
  let old_signal =
    Option.map
      (fun sigwinch ->
        ( Sys.signal sigwinch
            (Sys.Signal_handle
               (fun i ->
                 if i = sigwinch then terminal_size := fst @@ size () else ())),
          sigwinch ))
      sigwinch
  in
  let ansi_enabled = isatty && Option.is_some sigwinch in
  let printf = printf [ Foreground Blue ] in
  let print_history h i =
    match log_height with
    | Some log_height when ansi_enabled ->
        let rec refresh_history h n =
          match h with
          | a :: q when n <= log_height ->
              erase Eol;
              printf "%s"
                (String.sub a 0 @@ min (String.length a) (!terminal_size - 1));
              move_cursor 0 (-1);
              move_bol ();
              refresh_history q (n + 1)
          | _ ->
              move_cursor 0 n;
              move_bol ()
        in
        if i <= log_height then
          match h with
          | [] -> ()
          | line :: _ ->
              printf "%s\n"
                (String.sub line 0
                @@ min (String.length line) (!terminal_size - 1))
        else refresh_history h 0;
        flush_all ()
    | _ -> ()
  in
  let clean i =
    match log_height with
    | Some log_height when ansi_enabled ->
        for _ = 0 to Int.min i log_height do
          move_bol ();
          erase Eol;
          move_cursor 0 (-1)
        done;
        move_cursor 0 1
    | _ -> ()
  in
  let open Lwt.Syntax in
  let read_line () =
    let+ l = Lwt_io.read_line_opt ic in
    (`Std, l)
  and read_err_line () =
    let+ l = Lwt_io.read_line_opt ic_err in
    (`Err, l)
  in
  let next_lines () =
    let+ lines = Lwt.npick [ read_line (); read_err_line () ] in
    List.fold_left
      (fun lines res ->
        match res with _, None -> lines | kind, Some l -> (kind, l) :: lines)
      [] lines
  in
  let add_lines h acc acc_err lines =
    let add_line (acc, acc_err, history) line =
      match line with
      | `Std, l -> (out_acc acc l, acc_err, l :: history)
      | `Err, l -> (acc, out_acc_err acc_err l, l :: history)
    in
    List.fold_left add_line (acc, acc_err, h) lines
  in
  let rec process_new_line acc acc_err history i =
    let* lines = next_lines () in
    let acc, acc_err, history = add_lines history acc acc_err lines in
    match lines with
    | [] ->
        clean i;
        Lwt.return (acc, acc_err)
    | _ ->
        let i = i + List.length lines in
        print_history history i;
        process_new_line acc acc_err history i
  in
  (* Restore previous sigwinch handler. *)
  Fun.protect ~finally:(fun () ->
      Option.iter
        (fun (old_signal, sigwinch) -> Sys.set_signal sigwinch old_signal)
        old_signal)
  @@ fun () ->
  with_ref_set ANSITerminal.isatty (fun _ -> isatty)
  @@ fun () ->
  Lwt_main.run @@ process_new_line out_init [] [] 0 |> fun (acc, acc_err) ->
  (out_finish acc, acc_err)
