defmodule Jump.CredoChecks.LiveViewFormCanBeRehydrated do
  @moduledoc """
  Ensures that all forms with `phx-submit` have both an `id` attribute and a `phx-change` attribute specified.

  This is critical for form rehydration, since LiveView can't maintain form state across
  deploys or reconnects without an ID and phx-change, leading to the form being totally reset.
  Forms without `phx-submit` are not LiveView forms and don't need these attributes.

  Forms that opt out of recovery via `phx-auto-recover="ignore"` are not required to have
  `phx-change`, since they have explicitly disabled the rehydration behavior.

  The check recognizes `<form>`, `<.form>`, `<Form.form>` and `<PetalComponents.Form.form>`. If your
  project renders forms through its own wrapper component (for instance, the `<.simple_form>` that
  older Phoenix generators produced), list it in the `extra_form_components` param so those forms
  are checked too.
  """
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    param_defaults: [
      excluded: [],
      extra_form_components: []
    ],
    explanations: [
      check: """
      Ensures that all forms with `phx-submit` have both an `id` and `phx-change` attribute specified.

      This is critical for form rehydration, since LiveView can't maintain form state across
      deploys or reconnects without an ID and phx-change, leading to the form being totally reset.
      Forms without `phx-submit` are not LiveView forms and don't need these attributes.

      ✅ Good:

          <.form id="user-form" phx-submit="save" phx-change="validate">`

      ❌ Bad (missing ID and phx-change):

          <.form phx-submit="save">
      """,
      params: [
        excluded: "A list of path substrings. Files whose path contains any of them are not checked.",
        extra_form_components: """
        A list of additional form components to check, each written as the tag appears after the `<`
        (for instance, `".simple_form"` or `"MyAppWeb.Components.form"`).
        """
      ]
    ]

  alias Credo.Check.Params

  @doc false
  @impl Credo.Check
  def run(%SourceFile{filename: filename} = source_file, params \\ []) do
    if String.ends_with?(filename, ".ex") and not exclude_path?(filename, params) do
      issue_meta = IssueMeta.for(source_file, params)

      source_file
      |> Credo.Code.prewalk(&traverse(&1, &2, issue_meta))
      |> Enum.uniq()
    else
      []
    end
  end

  # Check the ~H sigil source directly for forms without IDs
  defp traverse({:sigil_H, _meta, [{:<<>>, meta, [heex]}, []]} = node, issues, parent_issue_meta)
       when is_binary(heex) do
    source_file = Credo.IssueMeta.source_file(parent_issue_meta)
    line = meta[:line]
    issue_meta = Credo.IssueMeta.for(source_file, line: line)
    form_patterns = form_patterns(IssueMeta.params(parent_issue_meta), "is missing 'id' attribute.")

    # Check the raw HEEX string for forms without IDs
    new_issues = check_heex_string_for_forms(heex, form_patterns, issue_meta, meta[:indentation], line)
    {node, issues ++ new_issues}
  end

  # Check embedded templates
  defp traverse({:embed_templates, _meta, template_patterns} = node, issues, issue_meta)
       when is_list(template_patterns) do
    source_file = Credo.IssueMeta.source_file(issue_meta)
    source_dir = Path.dirname(source_file.filename)

    # Find all .heex files in the templates directory
    new_issues =
      template_patterns
      |> Enum.flat_map(fn template_pattern ->
        source_dir
        |> Path.join(template_pattern)
        |> Path.wildcard()
        |> Enum.reject(&exclude_path?(&1, issue_meta))
        |> Enum.flat_map(fn heex_file ->
          check_heex_file(heex_file, issue_meta)
        end)
      end)
      |> Enum.uniq()

    {node, issues ++ new_issues}
  end

  defp traverse(node, issues, _issue_meta), do: {node, issues}

  # The form spellings to check, in order of specificity, as `{trigger, pattern, message}`.
  # Project-specific components come first, since they are the most specific of all.
  defp form_patterns(params, message_suffix) do
    extra_components =
      params
      |> Params.get(:extra_form_components, __MODULE__)
      |> List.wrap()
      |> Enum.map(&{&1, "Form component <#{&1}> #{message_suffix}"})

    builtin_components = [
      {"PetalComponents.Form.form", "Form component <PetalComponents.Form.form> #{message_suffix}"},
      {"Form.form", "Form component <Form.form> #{message_suffix}"},
      {".form", "Form component <.form> #{message_suffix}"},
      {"form", "Raw HTML <form> tag #{message_suffix}"}
    ]

    Enum.map(extra_components ++ builtin_components, fn {component, message} ->
      trigger = "<" <> component
      {trigger, Regex.compile!(Regex.escape(trigger) <> "\\b", "i"), message}
    end)
  end

  # Check a HEEX string for forms without IDs
  defp check_heex_string_for_forms(heex_string, form_patterns, issue_meta, indentation, base_line) do
    # First, find all form tags and check if they have IDs (handling multiline tags)
    find_forms_without_ids(heex_string, form_patterns, base_line + 1, indentation, issue_meta)
  end

  # Find form tags and check if they have IDs, handling multiline tags
  defp find_forms_without_ids(heex_string, form_patterns, base_line, indentation, issue_meta) do
    lines = heex_string |> String.split("\n") |> Enum.with_index(base_line)

    # Find all issues across all patterns, then deduplicate by line number
    # (keeping only the most specific pattern per line)
    form_patterns
    |> Enum.flat_map(fn {trigger, pattern, message} ->
      lines
      |> find_complete_tags(pattern, trigger, message)
      |> Enum.flat_map(fn tag ->
        tag
        |> Map.merge(%{indentation: indentation, issue_meta: issue_meta})
        |> form_complete_issues()
      end)
    end)
    |> deduplicate_issues_by_line()
  end

  # Deduplicate issues by line number, keeping only the most specific pattern
  # (first pattern in the list, since they're ordered by specificity)
  defp deduplicate_issues_by_line(issues) do
    issues
    |> Enum.group_by(fn issue -> issue.line_no end)
    |> Enum.map(fn {_line_no, line_issues} -> List.first(line_issues) end)
    |> Enum.sort_by(fn issue -> issue.line_no end)
  end

  # Find every opening tag matching `pattern`, with the attributes written between the tag name
  # and the tag's own closing `>`, which may sit several lines later. A tag that never closes is
  # dropped.
  defp find_complete_tags(lines, pattern, trigger, message) do
    lines
    |> Enum.reduce({[], nil}, fn
      # If we're tracking a tag, read this line's attributes up to the tag's closing `>`
      {line, _line_no}, {tags, %{} = open_tag} ->
        open_tag
        |> read_attributes(line)
        |> close_or_track(tags)

      # Otherwise, check if this line starts a new tag
      {line, line_no}, {tags, nil} ->
        case Regex.run(pattern, line, return: :index) do
          [{start, length} | _] ->
            # Only the text after the tag name belongs to this tag
            rest = binary_part(line, start + length, byte_size(line) - start - length)

            %{
              has_phx_submit?: false,
              has_id?: false,
              has_phx_validate?: false,
              has_auto_recover_ignore?: false,
              scan_state: {0, nil},
              tag_message: message,
              tag_line: line,
              tag_line_no: line_no,
              tag_trigger: trigger
            }
            |> read_attributes(rest)
            |> close_or_track(tags)

          nil ->
            {tags, nil}
        end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp read_attributes(tag, text) do
    {tag_text, scan_state} = tag_text(text, tag.scan_state)

    %{
      tag
      | has_phx_submit?: tag.has_phx_submit? or phx_submit?(tag_text),
        has_id?: tag.has_id? or id?(tag_text),
        has_phx_validate?: tag.has_phx_validate? or phx_change?(tag_text),
        has_auto_recover_ignore?: tag.has_auto_recover_ignore? or auto_recover_ignore?(tag_text),
        scan_state: scan_state
    }
  end

  defp close_or_track(%{scan_state: :closed} = tag, tags), do: {[tag | tags], nil}
  defp close_or_track(tag, tags), do: {tags, tag}

  # Returns the part of `text` that belongs to the tag, and either `:closed` when the tag's own
  # closing `>` is in `text`, or the state to carry onto the next line. A `>` inside a `{...}`
  # interpolation or a quoted attribute value does not close the tag, so `:if={@count > 0}` is
  # read as one attribute. A quote counts only outside interpolations, where it delimits a value.
  defp tag_text(text, state), do: tag_text(text, state, 0)

  defp tag_text(text, state, offset) when offset >= byte_size(text), do: {text, state}

  defp tag_text(text, {depth, quote_char} = state, offset) do
    case {:binary.at(text, offset), depth, quote_char} do
      {?>, 0, nil} -> {binary_part(text, 0, offset), :closed}
      {char, 0, nil} when char in [?", ?'] -> tag_text(text, {0, char}, offset + 1)
      {char, 0, char} -> tag_text(text, {0, nil}, offset + 1)
      {?{, depth, nil} -> tag_text(text, {depth + 1, nil}, offset + 1)
      {?}, depth, nil} when depth > 0 -> tag_text(text, {depth - 1, nil}, offset + 1)
      _other -> tag_text(text, state, offset + 1)
    end
  end

  # An attribute name must not be the tail of a longer name, so `phx-value-user-id=` is not an
  # `id` and `data-phx-change=` is not a `phx-change`.
  defp phx_submit?(text), do: Regex.match?(~r/(?<![\w-])phx-submit\s*=/i, text)
  defp id?(text), do: Regex.match?(~r/(?<![\w-])id\s*=/i, text)
  defp phx_change?(text), do: Regex.match?(~r/(?<![\w-])phx-change\s*=/i, text)

  defp auto_recover_ignore?(text), do: Regex.match?(~r/(?<![\w-])phx-auto-recover\s*=\s*["']ignore["']/i, text)

  defp form_complete_issues(%{has_phx_submit?: false}), do: []

  defp form_complete_issues(%{has_phx_submit?: true} = tag) do
    missing_attrs = missing_attrs(tag)

    if Enum.empty?(missing_attrs) do
      []
    else
      attr_list = missing_attrs |> Enum.reverse() |> Enum.join(" and ")

      custom_message =
        String.replace(
          tag.tag_message,
          "'id' attribute",
          "'#{attr_list}' #{if length(missing_attrs) == 1, do: "attribute", else: "attributes"}"
        )

      [create_form_issue(tag, custom_message)]
    end
  end

  defp missing_attrs(tag) do
    cond do
      tag.has_auto_recover_ignore? -> []
      tag.has_id? and tag.has_phx_validate? -> []
      tag.has_id? -> ["phx-change"]
      tag.has_phx_validate? -> ["id"]
      true -> ["id", "phx-change"]
    end
  end

  defp create_form_issue(tag, message) do
    # Find the position of the form opening
    [before | _after] = String.split(tag.tag_line, tag.tag_trigger)

    format_issue(tag.issue_meta,
      message: message,
      trigger: tag.tag_trigger,
      line_no: tag.tag_line_no,
      column: String.length(before) + (tag.indentation || 0) + 1
    )
  end

  # Check a .heex file for forms without IDs
  # sobelow_skip ["Traversal.FileModule"]
  defp check_heex_file(heex_file, parent_issue_meta) do
    content = File.read!(heex_file)
    params = IssueMeta.params(parent_issue_meta)
    issue_category = Params.category(params, __MODULE__)
    exit_status_or_category = Params.exit_status(params, __MODULE__) || issue_category

    find_forms_without_ids_in_heex_file(
      content,
      heex_file,
      params,
      issue_category,
      exit_status_or_category
    )
  end

  # Find form tags in .heex files and check if they have IDs
  defp find_forms_without_ids_in_heex_file(content, heex_file, params, issue_category, exit_status_or_category) do
    form_patterns = form_patterns(params, "found without an 'id' attribute.")
    lines = content |> String.split("\n") |> Enum.with_index(1)

    # Find all issues across all patterns, then deduplicate by line number
    # (keeping only the most specific pattern per line)
    form_patterns
    |> Enum.flat_map(fn {trigger, pattern, message} ->
      lines
      |> find_complete_tags(pattern, trigger, message)
      |> Enum.flat_map(&heex_file_issues(&1, heex_file, params, issue_category, exit_status_or_category))
    end)
    |> deduplicate_issues_by_line()
  end

  # Only report if tag has phx-submit but missing id or phx-change
  defp heex_file_issues(%{has_phx_submit?: false}, _heex_file, _params, _issue_category, _exit_status_or_category),
    do: []

  defp heex_file_issues(tag, heex_file, params, issue_category, exit_status_or_category) do
    missing_attrs = []
    missing_attrs = if tag.has_id?, do: missing_attrs, else: ["id" | missing_attrs]

    missing_attrs =
      if tag.has_phx_validate? or tag.has_auto_recover_ignore?,
        do: missing_attrs,
        else: ["phx-change" | missing_attrs]

    if Enum.empty?(missing_attrs) do
      []
    else
      attr_list = Enum.join(Enum.reverse(missing_attrs), " and ")

      custom_message =
        String.replace(
          tag.tag_message,
          "'id' attribute",
          "'#{attr_list}' #{if length(missing_attrs) == 1, do: "attribute", else: "attributes"}"
        )

      [
        create_heex_file_issue(
          tag.tag_line,
          tag.tag_line_no,
          heex_file,
          tag.tag_trigger,
          custom_message,
          params,
          issue_category,
          exit_status_or_category
        )
      ]
    end
  end

  defp create_heex_file_issue(
         line,
         line_no,
         heex_file,
         trigger,
         message,
         params,
         issue_category,
         exit_status_or_category
       ) do
    [before | _after] = String.split(line, trigger)

    %Issue{
      message: message,
      line_no: line_no,
      filename: heex_file,
      trigger: trigger,
      category: issue_category,
      check: __MODULE__,
      priority: Params.priority(params, __MODULE__),
      severity: Credo.Severity.default_value(),
      column: String.length(before) + 1,
      exit_status: Credo.Check.to_exit_status(exit_status_or_category)
    }
  end

  defp exclude_path?(path, issue_meta) when is_binary(path) and is_tuple(issue_meta) do
    params = Credo.IssueMeta.params(issue_meta)
    exclude_path?(path, params)
  end

  defp exclude_path?(filename, params) when is_binary(filename) and (is_list(params) or is_map(params)) do
    excluded_path_substrings = params |> Params.get(:excluded, __MODULE__) |> List.wrap()
    String.contains?(filename, excluded_path_substrings)
  end
end
