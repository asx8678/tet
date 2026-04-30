defmodule Tet.PromptTest do
  use ExUnit.Case, async: true

  test "builds deterministic provider-neutral messages and debug snapshot" do
    assert {:ok, first} = Tet.Prompt.build(prompt_attrs())
    assert {:ok, second} = Tet.Prompt.build(prompt_attrs())

    assert first.id == second.id
    assert first.hash == second.hash
    assert Tet.Prompt.debug(first) == Tet.Prompt.debug(second)
    assert Tet.Prompt.debug_text(first) == Tet.Prompt.debug_text(second)

    assert Enum.map(first.layers, & &1.kind) == [
             :system_base,
             :project_rules,
             :project_rules,
             :profile,
             :compaction_metadata,
             :attachment_metadata,
             :session_message
           ]

    assert List.last(Tet.Prompt.to_messages(first)) == %{
             role: :user,
             content: "Please refactor the prompt builder.",
             metadata: %{
               prompt_layer_hash:
                 "9441d9b9c39814716a3e1e1804b896ea293657c3b49e228cf3dfaea27c4c86bf",
               prompt_layer_id: "message:msg-user-1",
               prompt_layer_kind: "session_message"
             }
           }

    assert List.last(Tet.Prompt.to_provider_messages(first)) == %{
             role: "user",
             content: "Please refactor the prompt builder."
           }

    assert Tet.Prompt.debug_text(first) == debug_snapshot()
  end

  test "redacts sensitive metadata from debug output without dropping safe metadata" do
    assert {:ok, prompt} = Tet.Prompt.build(prompt_attrs())

    debug_text = Tet.Prompt.debug_text(prompt)

    refute debug_text =~ "You are Tet, a deterministic coding assistant."
    refute debug_text =~ "Please refactor the prompt builder."
    refute debug_text =~ "top-secret"
    refute debug_text =~ "rules-secret"
    refute debug_text =~ "compact-secret"
    refute debug_text =~ "Bearer nope"
    refute debug_text =~ "message-secret"

    assert debug_text =~ ~s("api_key":"[REDACTED]")
    assert debug_text =~ ~s("token":"[REDACTED]")
    assert debug_text =~ ~s("secret_note":"[REDACTED]")
    assert debug_text =~ ~s("authorization":"[REDACTED]")
    assert debug_text =~ ~s("access_token":"[REDACTED]")
    assert debug_text =~ ~s("safe_label":"handoff")
    assert debug_text =~ ~s("trace_id":"trace-1")
  end

  test "central redactor owns sensitive key matching" do
    assert Tet.Redactor.sensitive_key?(:api_key)
    assert Tet.Redactor.sensitive_key?("apikey")
    assert Tet.Redactor.sensitive_key?("bearer_header")
    assert Tet.Redactor.sensitive_key?("session_token")
    assert Tet.Redactor.sensitive_key?("accessToken")
    assert Tet.Redactor.sensitive_key?("refreshToken")
    assert Tet.Redactor.sensitive_key?("privateKey")
    assert Tet.Redactor.sensitive_key?("accessKey")
    assert Tet.Redactor.sensitive_key?("access-token")
    assert Tet.Redactor.sensitive_key?("private.key")

    refute Tet.Redactor.sensitive_key?("token_count")
    refute Tet.Redactor.sensitive_key?("tokenCount")
    refute Tet.Redactor.sensitive_key?(123)
    refute Tet.Redactor.sensitive_key?({:privateKey})

    assert Tet.Redactor.redact(%{"bearer_header" => "secret", :safe => "ok", 123 => "visible"}) ==
             %{
               "bearer_header" => "[REDACTED]",
               :safe => "ok",
               123 => "visible"
             }

    assert Tet.Redactor.redact(api_key: "secret", safe: {:token, "secret"}) ==
             [api_key: "[REDACTED]", safe: {:token, "[REDACTED]"}]

    already_redacted = ~s(api_key: "[REDACTED]")
    assert Tet.Redactor.redact(already_redacted) == already_redacted

    redacted_event =
      Tet.Redactor.redact(%Tet.Event{type: :provider_error, payload: %{api_key: "secret"}})

    assert redacted_event.payload == %{api_key: "[REDACTED]"}
  end

  test "redacts camelCase secret metadata keys at top-level and nested debug depths" do
    assert {:ok, prompt} =
             Tet.Prompt.build(
               system: "base",
               metadata: camel_secret_metadata(12),
               attachments: [
                 %{
                   name: "debug.json",
                   metadata: %{
                     nested: camel_secret_metadata(34)
                   }
                 }
               ]
             )

    debug = Tet.Prompt.debug(prompt)
    redacted = Tet.Redactor.redacted_value()

    for key <- ["accessToken", "refreshToken", "privateKey", "accessKey"] do
      assert debug.metadata[key] == redacted
    end

    assert debug.metadata["token_count"] == 12

    attachment_layer = Enum.find(debug.layers, &(&1.kind == "attachment_metadata"))
    [attachment] = attachment_layer.metadata["attachments"]
    nested = attachment["metadata"]["nested"]

    for key <- ["accessToken", "refreshToken", "privateKey", "accessKey"] do
      assert nested[key] == redacted
    end

    assert nested["token_count"] == 34

    debug_text = Tet.Prompt.debug_text(prompt)

    refute debug_text =~ "super-secret"
    assert debug_text =~ ~s("accessToken":"[REDACTED]")
    assert debug_text =~ ~s("privateKey":"[REDACTED]")
    assert debug_text =~ ~s("token_count":12)
    assert debug_text =~ ~s("token_count":34)
  end

  test "build! raises on invalid prompt input" do
    assert_raise ArgumentError, ~r/invalid prompt input/, fn ->
      Tet.Prompt.build!(messages: [])
    end
  end

  test "validates required system layer" do
    assert {:error, {:missing_prompt_layer, :system_base}} = Tet.Prompt.build(messages: [])
  end

  test "top-level aliases and map inputs produce equivalent prompt hashes" do
    keyword_prompt = Tet.Prompt.build!(system: "base", messages: [user_message()])

    map_prompt =
      Tet.Prompt.build!(%{
        "system_base" => "base",
        "session_messages" => [Tet.Message.to_map(user_message())]
      })

    assert keyword_prompt.hash == map_prompt.hash
    assert Enum.map(keyword_prompt.layers, & &1.id) == Enum.map(map_prompt.layers, & &1.id)
  end

  test "nil attachment fields are equivalent to omitted attachment fields" do
    omitted =
      Tet.Prompt.build!(
        system: "base",
        attachments: [%{name: "doc.md", media_type: "text/markdown"}]
      )

    explicit_nil =
      Tet.Prompt.build!(
        system: "base",
        attachments: [
          %{
            name: "doc.md",
            media_type: "text/markdown",
            byte_size: nil,
            sha256: nil,
            source: nil,
            metadata: %{}
          }
        ]
      )

    assert omitted.hash == explicit_nil.hash
    assert Enum.map(omitted.layers, & &1.id) == Enum.map(explicit_nil.layers, & &1.id)
  end

  test "empty attachment strings are treated as omitted metadata" do
    omitted =
      Tet.Prompt.build!(
        system: "base",
        attachments: [%{media_type: "text/plain"}]
      )

    empty_strings =
      Tet.Prompt.build!(
        system: "base",
        attachments: [
          %{name: "", media_type: "text/plain", sha256: "", source: ""}
        ]
      )

    assert omitted.hash == empty_strings.hash
    assert Enum.map(omitted.layers, & &1.id) == Enum.map(empty_strings.layers, & &1.id)
    assert Tet.Prompt.debug_text(omitted) == Tet.Prompt.debug_text(empty_strings)
    refute Tet.Prompt.debug_text(empty_strings) =~ ~s("name":"")
    refute Tet.Prompt.debug_text(empty_strings) =~ ~s("sha256":"")
    refute Tet.Prompt.debug_text(empty_strings) =~ ~s("source":"")
  end

  for field <- [:name, :media_type, :sha256, :source] do
    test "rejects non-string attachment #{field}" do
      attrs = [
        system: "base",
        attachments: [Map.put(%{byte_size: 1}, unquote(field), 123)]
      ]

      assert {:error, {:invalid_prompt_attachment, 0, unquote(field)}} = Tet.Prompt.build(attrs)
    end
  end

  test "rejects duplicate layer ids" do
    attrs = [
      system: "base",
      project_rules: [
        %{id: "rules:same", content: "one"},
        %{id: "rules:same", content: "two"}
      ]
    ]

    assert {:error, {:duplicate_prompt_layer_id, "rules:same"}} = Tet.Prompt.build(attrs)
  end

  test "rejects raw attachment payloads because attachments are metadata-only" do
    attrs = [
      system: "base",
      attachments: [%{name: "secret.txt", content: "do not prompt raw bytes"}]
    ]

    assert {:error, {:invalid_prompt_attachment, 0, :content_not_allowed}} =
             Tet.Prompt.build(attrs)
  end

  defp camel_secret_metadata(token_count) do
    %{
      "accessKey" => "super-secret",
      "accessToken" => "super-secret",
      "privateKey" => "super-secret",
      "refreshToken" => "super-secret",
      "token_count" => token_count
    }
  end

  defp prompt_attrs do
    [
      system: "You are Tet, a deterministic coding assistant.",
      metadata: %{request_id: "req-1", api_key: "top-secret"},
      project_rules: [
        %{
          id: "rules:global",
          source: "global",
          content: "Prefer CLI-first workflows.",
          metadata: %{owner: "ops"}
        },
        %{
          id: "rules:project",
          source: "project",
          content: "Keep files under 600 lines.",
          metadata: %{token: "rules-secret"}
        }
      ],
      profiles: [
        %{
          id: "profile:max",
          name: "Max",
          content: "Be playful, precise, and DRY.",
          metadata: %{mood: "puppy"}
        }
      ],
      compaction: %{
        id: "compact:1",
        summary: "Earlier turns established the runtime/store boundary.",
        source_message_ids: ["msg-old-1", "msg-old-2"],
        strategy: :rolling_summary,
        original_message_count: 8,
        retained_message_count: 2,
        metadata: %{secret_note: "compact-secret", token_count: 1234}
      },
      attachments: [
        %{
          name: "notes.md",
          media_type: "text/markdown",
          byte_size: 42,
          sha256: String.duplicate("a", 64),
          source: "autosave",
          metadata: %{safe_label: "handoff", authorization: "Bearer nope"}
        }
      ],
      messages: [user_message()]
    ]
  end

  defp user_message do
    %Tet.Message{
      id: "msg-user-1",
      session_id: "session-1",
      role: :user,
      content: "Please refactor the prompt builder.",
      timestamp: "2025-01-01T00:00:00.000Z",
      metadata: %{trace_id: "trace-1", access_token: "message-secret"}
    }
  end

  defp debug_snapshot do
    """
    tet.prompt.v1 id=prompt-301ebfac6ffa2666 hash=301ebfac6ffa26668cc5c69f32a7297d501274918648a6526a0bec9d91135279
    layers=7 messages=7 metadata={"api_key":"[REDACTED]","request_id":"req-1"}
    000 system_base role=system id=layer-000-system_base-8cb88d94ddbd hash=8cb88d94ddbdab2cdb91c511a27c36a91ebba433b726137524317e8451df2bc8 content_sha256=ab31ee68ed968807695a8aa9bdef29ecabeeccdde9e5e68b14b8ff2aa467d86d bytes=46 metadata={"source":"system_base"}
    001 project_rules role=system id=rules:global hash=dddef038a4589be0f5b597f47b0dd4ec691ec1758c76d0aea215601e3bde58f3 content_sha256=c2f1558d34a0b91dde57dcaa80b21fa517d11ef31465a533d953d7b288c5e491 bytes=27 metadata={"owner":"ops","source":"global"}
    002 project_rules role=system id=rules:project hash=58387dd38aa90ec56f2f3b079e0c3d06730b6e4cc2c1ecbfeff7b8392b846a05 content_sha256=f49ab8176f2437e7b0e5274d1130088fe418953edfa4ada06b2e7fe8dd4e1f5d bytes=27 metadata={"source":"project","token":"[REDACTED]"}
    003 profile role=system id=profile:max hash=9d77675632b82eef8b90240aadda5f917c6c7595f991d4c2f7dd23c16d37a46a content_sha256=8bf7a5a8d552a678e4d00a983aa488974bc18a5c2a27adc23f3083c05e3f703a bytes=29 metadata={"mood":"puppy","name":"Max"}
    004 compaction_metadata role=system id=compact:1 hash=94ca0a140c6b78e46156ef3eb295b9327306ed11de68eba2dcdf40292b1bc17d content_sha256=0f043e7f260d810823274f719debc1835eb54ee5f7d1bbc3e6adebc702d3a6bf bytes=222 metadata={"original_message_count":8,"retained_message_count":2,"secret_note":"[REDACTED]","source_message_ids":["msg-old-1","msg-old-2"],"strategy":"rolling_summary","token_count":1234}
    005 attachment_metadata role=system id=layer-005-attachment_metadata-0beb90941983 hash=0beb90941983cb1100e7ce2440a255de8159d6ae3716d8c1de4e6c8705573326 content_sha256=e8a96bd6aa2daaaa2031102319add8be361bfffff53b87f0fc0eb3baeb629cde bytes=205 metadata={"attachment_count":1,"attachments":[{"byte_size":42,"id":"attachment-9018c96c0275","media_type":"text/markdown","metadata":{"authorization":"[REDACTED]","safe_label":"handoff"},"name":"notes.md","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source":"autosave"}]}
    006 session_message role=user id=message:msg-user-1 hash=9441d9b9c39814716a3e1e1804b896ea293657c3b49e228cf3dfaea27c4c86bf content_sha256=727683c5e89189e11f083e1a5029aabd6d8208aa35630be5d722d6c02668dddf bytes=35 metadata={"message_id":"msg-user-1","message_metadata":{"access_token":"[REDACTED]","trace_id":"trace-1"},"session_id":"session-1","timestamp":"2025-01-01T00:00:00.000Z"}
    """
  end
end
