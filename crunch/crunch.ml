(*
 * Copyright (c) 2009-2011 Anil Madhavapeddy <anil@recoil.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

(* wrapper for realpath(2) *)
external realpath : string -> string = "unix_realpath"

(* repeat until End_of_file is raised *)
let repeat_until_eof fn =
   try while true do fn () done
   with End_of_file -> ()

(* Retrieve file extension , if any, or blank string otherwise *)
let get_extension ~filename =
  let rec search_dot i =
    if i < 1 || filename.[i] = '/' then None
    else if filename.[i] = '.' then Some (String.sub filename (i+1) (String.length filename - i - 1))
    else search_dot (i - 1) in
  search_dot (String.length filename - 1)

(* Walk directory and call walkfn on every file that matches extension ext *)
let walk_directory_tree ?ext walkfn root_dir =
  let rec walk dir =
    let dh = Unix.opendir dir in
    repeat_until_eof (fun () ->
      match Unix.readdir dh with
      | "." | ".." -> ()
      | f ->
          let n = Filename.concat dir f in
          if Sys.is_directory n then walk n
          else
            (match (get_extension f), ext with
            | (_, None) -> walkfn root_dir (String.sub n 2 (String.length n - 2))
            | (Some e, Some e') when e = e'  -> walkfn root_dir (String.sub n 2 (String.length n - 2))
            | _ -> ())
    );
    Unix.closedir dh in
  Unix.chdir root_dir;
  walk "."

open Arg
open Printf

let file_info = Hashtbl.create 1

let output_header oc =
  fprintf oc "(* This file has been autogenerated by %s *)\n" Sys.argv.(0);
  fprintf oc "module Internal = struct\n";
  fprintf oc "let file_chunks = function\n"

let output_file oc root name =
  let full_name = Filename.concat root name in
  let stats = Unix.stat full_name in
  let size = stats.Unix.st_size in
  Hashtbl.add file_info name size;
  fprintf oc " | \"%s\" | \"/%s\" -> Some [" (String.escaped name) (String.escaped name);
  let fin = open_in (Filename.concat root name) in
  let buf = Buffer.create size in
  Buffer.add_channel buf fin size;
  let s = Buffer.contents buf in
  close_in fin;
  (* Split the file as a series of chunks, of size up to 4096 (to simulate reading sectors) *)
  let sec = 4096 in (* sector size *)
  let rec consume idx =
     if idx = size then fprintf oc "]\n"; (* EOF *)
     if idx+sec < size then begin
       fprintf oc "\"%s\";\n" (String.escaped (String.sub s idx sec));
       consume (idx+sec);
     end else begin (* final chunk, short *)
       fprintf oc "\"%s\" ]\n" (String.escaped (String.sub s idx (size-idx)));
     end
  in
  consume 0

let output_footer oc =
  fprintf oc " | _ -> None\n";
  fprintf oc "\n";
  fprintf oc "let file_list = [";
  Hashtbl.iter (fun k _ ->  fprintf oc "\"%s\"; " (String.escaped k)) file_info;
  fprintf oc " ]\n";
  fprintf oc "let size = function\n";
  Hashtbl.iter (fun name size ->
    fprintf oc " |\"%s\" |\"/%s\" -> Some %dL\n" (String.escaped name) (String.escaped name) size
  ) file_info;
  fprintf oc " |_ -> None\n\n";
  fprintf oc "end\n\n"

let output_skeleton oc name =
  fprintf oc "let name=\"%s\"\n" name;
  let skeleton="
open Lwt

exception Error of string

let iter_s fn = Lwt_list.iter_s fn Internal.file_list

let size name = return (Internal.size name)

let read name =
  match Internal.file_chunks name with
  |None -> return None
  |Some c ->
     let chunks = ref c in
     return (Some (Lwt_stream.from (fun () ->
       match !chunks with
       |hd :: tl -> 
         chunks := tl;
         let pg = Cstruct.of_bigarray (OS.Io_page.get ()) in
         let len = String.length hd in
         Cstruct.blit_from_string hd 0 pg 0 len;
         return (Some (Cstruct.sub pg 0 len))
       |[] -> return None
     )))

let create vbd : OS.Devices.kv_ro Lwt.t =  
  return (object
    method iter_s fn = iter_s fn
    method read name = read name
    method size name = size name
  end)

let _ =
  let plug = Lwt_mvar.create_empty () in
  let unplug = Lwt_mvar.create_empty () in
  let provider = object(self)
    method id = name
    method plug = plug
    method unplug = unplug
    method create ~deps ~cfg id =
      Lwt.bind (create id) (fun kv ->
        let entry = OS.Devices.({
           provider=self;
           id=self#id;
           depends=[];
           node=KV_RO kv }) in
        return entry
      )
  end in
  OS.Devices.new_provider provider;
  OS.Main.at_enter (fun () -> Lwt_mvar.put plug {OS.Devices.p_id=name; p_dep_ids=[]; p_cfg=[]})

" in
  output_string oc skeleton

let _ =
  let dirs = ref [] in
  let ext = ref None in
  let name = ref "crunch" in
  let filename = ref None in
  let spec = [("-ext", String (fun e -> ext := Some e), "filter only these extensions");
              "-name", Set_string name, "Name of the VBD";
              "-o", String (fun f -> filename := Some f), "output in a file instead of stdout"
             ] in
  parse spec (fun s -> dirs := (realpath s) :: !dirs) 
    (sprintf "Usage: %s [-ext <filter extension>] [-o filename] <dir1> <dir2> ..." Sys.argv.(0));
  let ext = !ext in
  let oc = match !filename with None -> stdout | Some f -> open_out f in
  output_header oc;
  List.iter (walk_directory_tree ?ext (output_file oc)) !dirs;
  output_footer oc;
  output_skeleton oc !name
  

