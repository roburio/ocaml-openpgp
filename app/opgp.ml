open Rresult

(* git commit -SKEYIDHERE files
   /usr/bin/gpg
   --status-fd=2
   -b (* detached sig *)
   -s (* sign *)
   -a (* create ASCII-armored sig *)
   -u (* keyid *)
   "6F16B4AC46B2FB2E5C86716E30543734"...]
*)

(* TODO set umask when writing files *)
let cs_of_file name =
  Fpath.of_string name >>= Bos.OS.File.read >>| Cs.of_string
  |> R.reword_error (fun _ -> `Msg "Can't open file for reading")

let file_cb filename : unit -> ('a,'b)result =
  (* TODO read file in chunks *)
  let content = ref (fun () -> cs_of_file filename >>| (fun cs -> Some cs)) in
  (fun () ->
     let x = !content () in
     content := (fun () -> Ok None); x
  )
    (*
    Bos.OS.File.with_ic filepath
      (fun ic -> fun _ ->
         (fun () ->
            let buf = Bytes.create 8192 in
            match input ic buf 0 8192 with
            | exception Sys_error _ -> Ok None (* TODO not sure this is the way to go*)
            | 0 -> Ok None
            | x ->
              Printf.eprintf "got some bytes: %S!" (Bytes.to_string buf);
              Ok (Some ((Bytes.sub buf 0 x) |> Cstruct.of_bytes))
         )
      ) 0
    |> R.reword_error (fun e -> Printf.printf "whatt\n";e) |> R.get_ok
    *)

let do_verify _ current_time pk_file detached_file target_file
  : (unit, [ `Msg of string ]) Result.result =
  let res =
  cs_of_file pk_file >>= fun pk_content ->
  cs_of_file detached_file >>= fun detached_content ->
  Logs.info
  (fun m -> m "Going to verify that '%S' is a signature on '%S' using key '%S'"
      detached_file target_file pk_file) ;

  Openpgp.decode_public_key_block ~current_time pk_content >>= fun (tpk, _) ->
  Openpgp.decode_detached_signature detached_content >>= fun detached_sig ->
  begin match Openpgp.Signature.verify_detached_cb
                ~current_time tpk detached_sig (file_cb target_file) with
    | Ok `Good_signature ->
      Logs.app (fun m -> m "Good signature!"); Ok ()
    | (Error (`Msg err)) ->
      Types.error_msg (fun m -> m "BAD signature: @[%a@]" Fmt.text err)
  end
  in res |> R.reword_error Types.msg_of_error

let do_convert _ current_time secret_file =
 (cs_of_file secret_file
  >>= Openpgp.decode_secret_key_block ~current_time >>| fst
  >>| Openpgp.Signature.transferable_public_key_of_transferable_secret_key
  >>= Openpgp.serialize_transferable_public_key
  >>= Openpgp.encode_ascii_armor Types.Ascii_public_key_block >>| fun cs ->
  Logs.app (fun m -> m "%s" (Cs.to_string cs))
 )|> R.reword_error Types.msg_of_error

let do_genkey _ g current_time uid pk_algo =
  (* TODO only create encryption key if pk_algo supports encryption *)
  Public_key_packet.generate_new ~current_time ?g pk_algo >>= fun root_key ->
  Public_key_packet.generate_new ~current_time ?g pk_algo >>= fun signing_key ->
  Public_key_packet.generate_new ~current_time ?g pk_algo >>= fun encrypt_key ->
  Openpgp.new_transferable_secret_key ~current_time Types.V4
    root_key [uid]
    Types.[ signing_key, create_key_usage_flags ~sign_data:true ()
          ; encrypt_key, create_key_usage_flags ~encrypt_storage:true ~encrypt_communications:true () ]
  >>= Openpgp.serialize_transferable_secret_key Types.V4
  >>= fun key_cs ->
  Openpgp.encode_ascii_armor Types.Ascii_private_key_block key_cs
  >>| fun encoded_pk ->
  Logs.app (fun m -> m "%s" (Cs.to_string encoded_pk))

let do_list_packets _ g target =
  Logs.info (fun m ->
      m "Listing packets in ascii-armored structure in %s" target) ;
  let res =
    cs_of_file target >>= fun armor_cs ->
    let arm_typ, raw_cs, todo_leftover =
      Logs.on_error ~level:Logs.Info
        ~use:(fun _ -> None, armor_cs, Cs.empty)
        ~pp:(fun fmt _ ->
            Fmt.pf fmt "File doesn't look ascii-armored, trying to parse as-is")
        (Openpgp.decode_ascii_armor ~allow_trailing:false armor_cs
         >>| fun (a,c,l) -> Some a,c,l)
    in
    Logs.app (fun m -> m "armor type: %a"
                 (Fmt.option ~none:(Fmt.unit "None")
                    Types.pp_ascii_packet_type) arm_typ
             );
    Logs.info (fun m -> m "@.%a" Cs.pp_hex raw_cs ) ;
    Openpgp.parse_packets ?g raw_cs
    >>= fun pkts_tuple ->
    (* TODO Only print hexdump if -v is passed *)
    Logs.app (fun m -> m "Packets:@.|  %a"
                 (fun fmt -> Fmt.pf fmt "%a"
                     Fmt.(list ~sep:(unit "@.|  ")
                            (vbox @@ pair ~sep:(unit "@,Hexdump: ")
                               Openpgp.pp_packet Cs.pp_hex ))
                 ) pkts_tuple
             ) ; Ok ()
  in
  res |> R.reword_error Types.msg_of_error

let do_sign _ g current_time secret_file target_file =
  (
  cs_of_file secret_file >>= fun sk_cs ->
  cs_of_file target_file >>= fun target_content ->
  Openpgp.decode_secret_key_block ?g ~current_time sk_cs
  >>| Types.log_msg (fun m -> m "parsed secret key") >>= fun (tsk,_) ->
  (* TODO pick hash algo from Preferred_hash_algorithms *)
  Openpgp.Signature.sign_detached_cs ~current_time tsk
    Types.SHA384 target_content >>= fun sig_t ->
  Openpgp.serialize_packet Types.V4 (Openpgp.Signature_type sig_t)
  >>= Openpgp.encode_ascii_armor Types.Ascii_signature
  >>| Cs.to_string >>= fun encoded ->
  Logs.app (fun m -> m "%s" encoded) ; Ok ()
  )|> R.reword_error Types.msg_of_error

let do_decrypt _ rng current_time secret_file target_file =
  ( cs_of_file secret_file >>= fun sk_cs ->
    cs_of_file target_file >>= fun target_content ->
    Openpgp.decode_secret_key_block ?g:rng ~current_time sk_cs
    >>| Types.log_msg (fun m -> m "parsed secret key") >>= fun (secret_key,_) ->
    ( Openpgp.decode_message target_content
      |>  R.reword_error Types.msg_of_error)
    >>= Openpgp.decrypt_message ~current_time ~secret_key
    >>| fun ({ Literal_data_packet.filename ; _}, decrypted) ->
    Logs.info (fun m -> m "Suggested filename: %S" filename) ;
    print_string decrypted
  ) |> R.reword_error Types.msg_of_error

let do_mail_decrypt _ rng current_time secret_file target_file =
  ( cs_of_file secret_file
    >>= Openpgp.decode_secret_key_block ?g:rng ~current_time
    |>  R.reword_error Types.msg_of_error
  ) >>= fun (secret_key, _) ->
  Logs.debug (fun m -> m "Going to decode the email in %S" target_file);
  let open MrMime in
  let (read_input, read_buffer, _close) =
    let ch = open_in_bin target_file in
    let read_buffer = Bytes.make 1024 '\000' in
    let len = Bytes.length read_buffer in
    ((fun () -> input ch read_buffer 0 len), read_buffer,
     (fun () -> close_in ch)) in
  let rec get decoder =
    match Convenience.decode decoder with
    | `Continue ->
      let n = read_input () in (* Read another chunk, *)
      Convenience.src decoder read_buffer 0 n; (* hand it to the decoder, *)
      get decoder (* and carry on parsing *)
    | `Done v -> Ok v
    | `Error _exn -> Error (`Msg "Error during parsing") in
  let decoder = Convenience.decoder
      (Input.create_bytes 4096) Message.Decoder.p_message in
  get decoder >>= fun (header, message) ->
  begin match message with
    | Message.Multipart (content,b,next_parts) -> Ok (content, next_parts)
    | _ -> R.error_msgf "Email is not Multipart; can't be PGP/MIME"
  end >>= fun (content, tl_content) ->
  Logs.debug (fun m -> m "Outer content: %a@.%a@." Header.pp header Content.pp content);
  begin match content.Content.ty with
    | {ContentType.ty = `Multipart ; subty = `Iana_token "encrypted"
      ; _}  as xx when List.exists
          (function "protocol", `String "application/pgp-encrypted" -> true
                  | _ -> false) xx.ContentType.parameters ->
      Logs.debug (fun m -> m "%a\n" ContentType.pp xx) ; Ok ()
    | _ -> R.error_msgf "Email mime type is not application/pgp-encrypted: %a"
             Content.pp content
  end >>= fun () ->
  let our_potential_addrs = Header.(header.to' @ header.cc @ header.bcc) in
  List.map (fun x ->
      (* Foo <baz@bar.example> *)
      Logs.debug (fun m -> m "%a -- %s\n" Address.pp x (Address.to_string x));
      x |>function (`Group xxx:Address.address) -> [""]
                 | `Mailbox x ->
                   begin match x.Address.name with
                     | None -> []
                     | Some name ->
                       List.map (function `Dot -> "." | `Encoded (a,b) -> a
                                        | `Word (`Atom x| `String x) -> x) name
                   end @
                   List.map
                     (fun domain ->
                        (String.concat "_" @@
                         List.map (function `Atom x -> x
                                          | `String x -> x) x.Address.local)
                        ^ "@" ^ begin match domain with
                          | `Domain labels -> String.concat "." labels
                          | `Literal (Rfc5321.IPv4 v4a)->
                            Ipaddr.to_string (V4 v4a)
                          | `Literal (Rfc5321.IPv6 v6a) ->
                            Ipaddr.to_string (V6 v6a)
                        end) (fst x.Address.domain :: snd x.Address.domain)
    )
    our_potential_addrs |> List.flatten
  |> fun abc ->
  Logs.info (fun m -> m "Potential receiver UIDs: %a@,"
                Fmt.(list ~sep:(unit " ;; ") string) abc);
  begin match tl_content with | [] -> R.error_msgf "TODO" | x::tl -> Ok (x,tl)
  end >>= fun ((content, _, _message),tl_content) ->
  Logs.debug (fun m -> m "@.content_msg: %a@." Content.pp content);
  begin match content.Content.ty with
    | {ContentType.ty = `Application ; subty = `Iana_token "pgp-encrypted"
      ; parameters = [] } -> Ok ()
    | _ -> R.error_msgf "well PART 1 this is not for us: @,%a"
             ContentType.pp content.Content.ty
  end >>= fun () ->
  (* _message here usually contains "Version: 1" *)

  begin match tl_content with | [] -> R.error_msgf "TODO" | x::tl -> Ok (x,tl)
  end >>= fun ((content, _, message),tl_content) ->
  Fmt.pr "@.content_msg2: %a@." Content.pp content;
  begin match content.Content.ty, content.Content.description with
    | {ContentType.ty = `Application ; subty = `Iana_token "octet-stream"
      ; parameters = ["name" , `Token "encrypted.asc"] },
      (* ^-- question for dinosaure: may this could be a Set?*)
      Some [`WSP; `Text "OpenPGP";
            `WSP; `Text "encrypted";
            `WSP; `Text "message"] -> Ok ()
    | _ -> Error (`Msg "well PART 2 this is not for us")
  end >>= fun () ->

  begin match message with
    | Some Message.PDiscrete Message.Raw raw_msg ->
      Logs.debug (fun m -> m "Got PGP message body");
      Openpgp.decode_message ?g:rng ~armored:true (Cs.of_string raw_msg)
      |> R.reword_error Types.msg_of_error
      >>= Openpgp.decrypt_message ~current_time ~secret_key
      |> R.reword_error Types.msg_of_error
      >>= fun ({Literal_data_packet.filename ; _},b) ->
      Logs.app (fun m -> m "DECRYPTED %S: %s" filename b);
      Ok ()
    | _ -> R.error_msgf "Unable to decode MIME part"
  end >>= fun () ->
  Types.true_or_error (tl_content = [])
    (fun m -> m "This PGP/MIME email seems to have more parts; not \
                 sure how to handle that.")

let do_encrypt _ rng current_time public_file target_file =
  ( cs_of_file public_file >>= Openpgp.decode_public_key_block ~current_time
    >>= fun (tpk, _) ->

    cs_of_file target_file >>= fun target_content ->
    ( Openpgp.encrypt_message ?rng ~current_time
        ~public_keys:[tpk] target_content
      |>  R.reword_error Types.msg_of_error)
    >>= Openpgp.encode_message ~armored:true
    >>| Cs.to_string >>| print_string
  ) |> R.reword_error Types.msg_of_error


open Cmdliner

let docs = Manpage.s_options
let sdocs = Manpage.s_common_options

let setup_log =
  let _setup_log (style_renderer:Fmt.style_renderer option) level : unit =
    Fmt_tty.setup_std_outputs ?style_renderer () ;
    Logs.set_level level ;
    Logs.set_reporter (Logs_fmt.reporter ())
  in
  Term.(const _setup_log $ Fmt_cli.style_renderer ~docs:sdocs ()
                        $ Logs_cli.level ~docs:sdocs ())

let pk =
  let doc = "Path to a file containing a public key" in
  Arg.(required & opt (some non_dir_file) None & info ["pk"] ~docs ~doc)
let sk =
  let doc = "Path to a file containing a secret/private key" in
  Arg.(required & opt (some non_dir_file) None & info ["sk";"secret"] ~docs ~doc)
let signature =
  let doc = "Path to a file containing a detached signature" in
  Arg.(required & opt (some non_dir_file) None & info ["signature"] ~docs ~doc)

let rng_seed : Nocrypto.Rng.g option Cmdliner.Term.t =
  let doc = {|Manually supply a hex-encoded seed for the pseudo-random number
              generator. Used for debugging; SHOULD NOT be used for generating
              real-world keys!" |} in
  let random_seed : Nocrypto.Rng.g option Cmdliner.Arg.parser = fun seed_hex ->
    (Cs.of_hex seed_hex |> R.reword_error
        (fun _ -> Fmt.strf "--rng-seed: invalid hex string: %S" seed_hex)
      >>| fun seed ->
     Logs.warn (fun m -> m "PRNG from seed %a" Cs.pp_hex seed) ;
     Some (Nocrypto.Rng.create ~seed:(Cs.to_cstruct seed)
             (module Nocrypto.Rng.Generators.Fortuna))
    ) |> R.to_presult
  in
  Arg.(value & opt (random_seed, (fun fmt _ -> Format.fprintf fmt "OS PRNG"))
       None & info ["rng-seed"] ~docs ~doc)

let override_timestamp : Ptime.t Cmdliner.Term.t =
  let doc = "Manually override the current timestamp (useful for reproducible debugging)" in
  let current_time t =
     (* TODO this can't express the full unix timestamp on 32-bit *)
     let error = `Error ("Unable to parse override-time=" ^ t) in
     match int_of_string t |> Ptime.Span.of_int_s |> Ptime.of_span with
     | exception _ -> error | None -> error
     | Some time -> Logs.warn
        (fun m -> m "Overriding current timestamp, set to %a" Ptime.pp time)
        ; `Ok time
  in
  Arg.(value & opt (current_time, Ptime.pp) (Ptime_clock.now ())
             & info ["override-timestamp"] ~docs ~doc)

let target =
  let doc = "Path to target file" in
  Arg.(required & pos 0 (some non_dir_file) None
       & info [] ~docv:"FILE" ~docs ~doc)

let uid =
  let doc = "User ID text string (name and/or email, the latter enclosed \
             in <brackets>)" in
  Arg.(required & opt (some string) None & info ["uid"] ~docs ~doc)

let pk_algo : Types.public_key_algorithm Cmdliner.Term.t =
  let doc = "Public key algorithm (either $(b,RSA) or $(b,DSA))" in
  let convert s = s |> Types.public_key_algorithm_of_string
                  |> function Ok x -> `Ok x | Error (`Msg x) -> `Error x in
  Arg.(value & opt (convert, Types.pp_public_key_algorithm)
         Types.RSA_encrypt_or_sign
       & info ["algo";"type";"pk-algo"] ~docs ~doc)

let genkey_cmd =
  let doc = "Generate a new secret key" in
  let man = [
    `S Manpage.s_synopsis ;
    `P "$(mname) $(tname) $(b,--uid) $(i,'My name') [$(i,OPTIONS)]" ;
    `S Manpage.s_description ;
    `P {|This command generate a new secret key.
         The secret key can issues signature using $(mname) $(b,sign).
         The corresponding public key can be exported using $(mname)
         $(b,convert).|} ;
    (*^TODO this is aworkaround https://github.com/dbuenzli/cmdliner/issues/82*)
    ]
  in
  Term.(term_result (const do_genkey $ setup_log $ rng_seed $ override_timestamp
                                     $ uid $ pk_algo)),
  Term.info "genkey" ~doc ~sdocs ~exits:Term.default_exits ~man
    ~man_xrefs:[`Cmd "convert"]

let convert_cmd =
  let doc = "Convert a secret/private key to a public key" in
  let man = [
    `S Manpage.s_synopsis ;
    `P "$(mname) $(tname) $(i,FILE) [$(i,OPTIONS)]" ;
    `S Manpage.s_description ;
    `P {|This command can be used to export a public key contained in a secret
         key $(i,FILE) to a public key that is usable with the $(mname)
         $(b,verify) command, and for giving to other people.
         This is useful after generating a key using $(mname) $(b,genkey).|} ;
  ]
  in
  Term.(term_result (const do_convert $ setup_log $ override_timestamp
                                      $ target)),
  Term.info "convert" ~doc ~sdocs ~exits:Term.default_exits ~man
    ~man_xrefs:[`Cmd "verify"; `Cmd "genkey"]

let verify_cmd =
  let doc = "Verify a detached signature on a file" in
  let man = [
    `S Manpage.s_synopsis ;
    `P {|$(tname) [$(i,OPTIONS)] $(b,--pk) $(i,public-key.asc) $(b,--sig)
                   $(i,detached-signature.asc) $(i,FILE) |} ;
    `S Manpage.s_description ;
    `P {|Verify that the $(i,signature) is a signature on $(i,FILE) issued
         by $(i,pk). |};
    ]
  in
  Term.(term_result (const do_verify $ setup_log $ override_timestamp $ pk
                                     $ signature $ target)),
  Term.info "verify" ~doc ~sdocs
    ~exits:Term.default_exits ~man
    ~man_xrefs:[`Cmd "sign"]

let decrypt_cmd =
  let doc = "Decrypt a PGP-encrypted file" in
  let man = [
    `S Manpage.s_synopsis ;
    `P {|$(tname) [$(i,OPTIONS)] $(b,--sk) $(i,private-key.asc) $(i,FILE) |} ;
    `S Manpage.s_description ;
    `P {|Decrypt the $(i,FILE) using the provided secret key.|};
    ]
  in
  Term.(term_result (const do_decrypt $ setup_log $ rng_seed
                     $ override_timestamp
                     $ sk $ target)),
  Term.info "decrypt" ~doc ~sdocs
    ~exits:Term.default_exits ~man
    ~man_xrefs:[`Cmd "mail-decrypt"; `Cmd "encrypt"]

let encrypt_cmd =
  let doc = "Encrypted a file to a public key" in
  let man = [
    `S Manpage.s_synopsis ;
    `P {|$(tname) [$(i,OPTIONS)] $(b,--sk) $(i,public-key.asc) $(i,FILE) |} ;
    `S Manpage.s_description ;
    `P {|Encrypt the $(i,FILE) using the provided public key.|};
    ]
  in
  Term.(term_result (const do_encrypt $ setup_log $ rng_seed
                     $ override_timestamp
                     $ pk $ target)),
  Term.info "encrypt" ~doc ~sdocs
    ~exits:Term.default_exits ~man
    ~man_xrefs:[`Cmd "mail-encrypt"; `Cmd "decrypt";]


let list_packets_cmd =
  let doc = "Pretty-print the packets contained in a file" in
  let man = [
    `S Manpage.s_description ;
    `P {|This subcommand is similar in purpose to $(b,gpg --list-packets).|}
  ] in
  Term.(term_result (const do_list_packets $ setup_log $ rng_seed $ target)),
  Term.info "list-packets" ~doc ~sdocs
            ~exits:Term.default_exits ~man

let mail_decrypt_cmd =
  let doc = "Decrypt a PGP/MIME-encrypted email" in
  let man = []
  in
  Term.(term_result (const do_mail_decrypt $ setup_log $ rng_seed
                     $ override_timestamp
                     $ sk $ target)),
  Term.info "mail-decrypt" ~doc ~sdocs
    ~exits:Term.default_exits ~man
    ~man_xrefs:[`Cmd "decrypt"; `Cmd "mail-encrypt"]


let sign_cmd =
  let doc = "Produce a detached signature on a file" in
  let man = [
    `S Manpage.s_synopsis ;
    `P {| $(mname) $(tname) [$(i,OPTIONS)] $(b,--sk) $(i,secret-key.asc FILE)|};
    `S Manpage.s_description ;
    `P {|Takes a $(i,secret key) and a $(i,FILE) as arguments and outputs an
         ASCII-armored signature that can be used with the corresponding
         public key to verify the authenticity of the target $(i,FILE). |} ;
    `P "This is similar to GnuPG's $(b,--detach-sign)" ;
    ]
  in
  Term.(term_result (const do_sign $ setup_log $ rng_seed $ override_timestamp
                                   $ sk $ target)),
  Term.info "sign" ~doc ~exits:Term.default_exits ~man ~sdocs
                   ~man_xrefs:[`Cmd "verify"]

let help_cmd =
  let doc = {| $(mname) is a commandline interface to the OCaml-OpenPGP
               library. |} in
  let man =
[
  `S "DESCRIPTION" ;
  `P {|This application aims to be a memory-safe language alternative to the
       functionality provided by GnuPG's $(b,gpg2) command.
       $(mname) implements the parts of the OpenPGP standard (RFC 4880) that
       concerns  cryptographic signing.
       It $(i,does not handle encryption or web-of-trust), and was originally inspired by the
       wish to be able to verify PGP signatures from software authors.|} ;
  `S "USAGE" ;
  `P {|Note that you only have to type out a unique prefix for the subcommands.
       That means that $(mname) $(b,l) is an alias for
       $(mname) $(b,list-packets) ;
       That $(mname) $(b,v) is an alias for $(mname) $(b,verify) and so forth.|}
 ;`P {|The same is the case for options,
       so $(b,--rng) is an alias for $(b,--rng-seed) ;|} ;
  `Noblank ;
  `P {|$(mname) $(b,v) $(b,--sig) $(i,file.asc) is equivalent to
       $(mname) $(b,verify) $(b,--signature) $(i,file.asc) |} ;
  `S "EXAMPLES" ;
  `P "# $(mname) $(b,genkey --uid) 'Abbot Hoffman' $(b,>) abbie.priv" ;
  `P "# $(mname) $(b,sign --sk) abbie.priv MKULTRA.DOC $(b,>) MKULTRA.DOC.asc" ;
  `P "# $(mname) $(b,convert) abbie.priv $(b,>) abbie.pub" ;
  `P {|# $(mname) $(b,verify --sig) MKULTRA.DOC.asc $(b,--pk) abbie.pub
                   MKULTRA.DOC |} ; `Noblank ;
  `Pre {|opgp: [ERROR] Failed decoding ASCII armor ASCII public key block,
              parsing as raw instead|} ; `Noblank ;
  `P "Good signature!" ;
  `P {|# $(b,echo \$?) |}; `Noblank ;
  `P "0" ;
  `S Manpage.s_bugs;
  `P ( "Please report bugs on the issue tracker at "
     ^ "<https://github.com/cfcs/ocaml-openpgp/issues>") ]
  in
  let help _ = `Help (`Pager, None) in
  Term.(ret (const help $ setup_log)),
  Term.info "opgp" ~version:(Manpage.escape "%%VERSION_NUM%%") ~man ~doc ~sdocs

let cmds = [ verify_cmd ; genkey_cmd; convert_cmd; list_packets_cmd; sign_cmd ;
             decrypt_cmd ; encrypt_cmd; mail_decrypt_cmd ]

let () =
  Nocrypto_entropy_unix.initialize () ;
  Term.(exit @@ eval_choice help_cmd cmds)
