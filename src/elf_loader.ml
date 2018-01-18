(**************************************************************************)
(*     Sail                                                               *)
(*                                                                        *)
(*  Copyright (c) 2013-2017                                               *)
(*    Kathyrn Gray                                                        *)
(*    Shaked Flur                                                         *)
(*    Stephen Kell                                                        *)
(*    Gabriel Kerneis                                                     *)
(*    Robert Norton-Wright                                                *)
(*    Christopher Pulte                                                   *)
(*    Peter Sewell                                                        *)
(*    Alasdair Armstrong                                                  *)
(*                                                                        *)
(*  All rights reserved.                                                  *)
(*                                                                        *)
(*  This software was developed by the University of Cambridge Computer   *)
(*  Laboratory as part of the Rigorous Engineering of Mainstream Systems  *)
(*  (REMS) project, funded by EPSRC grant EP/K008528/1.                   *)
(*                                                                        *)
(*  Redistribution and use in source and binary forms, with or without    *)
(*  modification, are permitted provided that the following conditions    *)
(*  are met:                                                              *)
(*  1. Redistributions of source code must retain the above copyright     *)
(*     notice, this list of conditions and the following disclaimer.      *)
(*  2. Redistributions in binary form must reproduce the above copyright  *)
(*     notice, this list of conditions and the following disclaimer in    *)
(*     the documentation and/or other materials provided with the         *)
(*     distribution.                                                      *)
(*                                                                        *)
(*  THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS''    *)
(*  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED     *)
(*  TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A       *)
(*  PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR   *)
(*  CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,          *)
(*  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT      *)
(*  LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF      *)
(*  USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND   *)
(*  ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,    *)
(*  OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT    *)
(*  OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF    *)
(*  SUCH DAMAGE.                                                          *)
(**************************************************************************)

module Big_int = Nat_big_num

let opt_elf_threads = ref 1
let opt_elf_entry = ref Big_int.zero

type word8 = int

let escape_char c =
  if int_of_char c <= 31 then '.'
  else if int_of_char c >= 127 then '.'
  else c

let hex_line bs =
  let hex_char i c =
    (if i mod 2 == 0 && i <> 0 then " " else "") ^ Printf.sprintf "%02x" (int_of_char c)
  in
  String.concat "" (List.mapi hex_char bs) ^ " " ^ String.concat "" (List.map (fun c -> Printf.sprintf "%c" (escape_char c)) bs)

let rec break n = function
  | [] -> []
  | (_ :: _ as xs) -> [Lem_list.take n xs] @ break n (Lem_list.drop n xs)

let print_segment seg =
  let (Byte_sequence.Sequence bs) = seg.Elf_interpreted_segment.elf64_segment_body in
  prerr_endline "0011 2233 4455 6677 8899 aabb ccdd eeff 0123456789abcdef";
  List.iter (fun bs -> prerr_endline (hex_line bs)) (break 16 bs)

let read name =
  let info = Sail_interface.populate_and_obtain_global_symbol_init_info name in

  prerr_endline "Elf read:";
  let (elf_file, elf_epi, symbol_map) =
    begin match info with
    | Error.Fail s -> failwith (Printf.sprintf "populate_and_obtain_global_symbol_init_info: %s" s)
    | Error.Success ((elf_file: Elf_file.elf_file),
                     (elf_epi: Sail_interface.executable_process_image),
                     (symbol_map: Elf_file.global_symbol_init_info))
      ->
       prerr_endline (Sail_interface.string_of_executable_process_image elf_epi);
       (elf_file, elf_epi, symbol_map)
    end
  in

  prerr_endline "\nElf segments:";
  let (segments, e_entry, e_machine) =
    begin match elf_epi, elf_file with
    | (Sail_interface.ELF_Class_32 _, _) -> failwith "cannot handle ELF_Class_32"
    | (_, Elf_file.ELF_File_32 _)  -> failwith "cannot handle ELF_File_32"
    | (Sail_interface.ELF_Class_64 (segments, e_entry, e_machine), Elf_file.ELF_File_64 f1) ->
       (* remove all the auto generated segments (they contain only 0s) *)
       let segments =
         Lem_list.mapMaybe
           (fun (seg, prov) -> if prov = Elf_file.FromELF then Some seg else None)
           segments
       in
       (segments, e_entry, e_machine)
    end
  in
  (segments, e_entry)

let load_segment seg =
  let open Elf_interpreted_segment in
  let (Byte_sequence.Sequence bs) = seg.elf64_segment_body in
  let paddr = seg.elf64_segment_paddr in
  let base = seg.elf64_segment_base in
  let offset = seg.elf64_segment_offset in
  prerr_endline "\nLoading Segment";
  prerr_endline ("Segment offset: " ^ Big_int.to_string offset);
  prerr_endline ("Segment base address: " ^ Big_int.to_string base);
  prerr_endline ("Segment physical address: " ^ Big_int.to_string paddr);
  print_segment seg;
  List.iteri (fun i byte -> Sail_lib.wram (Big_int.add paddr (Big_int.of_int i)) byte) (List.map int_of_char bs)

let load_elf name =
  let segments, e_entry = read name in
  opt_elf_entry := e_entry;
  List.iter load_segment segments

(* The sail model can access this by externing a unit -> int function
   as Elf_loader.elf_entry. *)
let elf_entry () = !opt_elf_entry