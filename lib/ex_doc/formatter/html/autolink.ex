defmodule ExDoc.Formatter.HTML.Autolink do
  @moduledoc """
  Conveniences for autolinking locals, types and more.
  """

  @elixir_docs "http://elixir-lang.org/docs/stable/"
  @erlang_docs "http://www.erlang.org/doc/man/"

  @doc """
  Escape `'`, `"`, `&`, `<` and `>` in the string using HTML entities.
  This is only intended for use by the HTML formatter.
  """
  def escape_html(binary) do
    escape_map = [{ ~r(&), "\\&amp;" }, { ~r(<), "\\&lt;" }, { ~r(>), "\\&gt;" }, { ~r("), "\\&quot;" }]
    Enum.reduce escape_map, binary, fn({ re, escape }, acc) -> Regex.replace(re, acc, escape) end
  end

  @doc """
  Receives a list of module nodes and autolink all docs and typespecs.
  """
  def all(modules) do
    aliases = Enum.map modules, &(&1.module)
    project_funs = for m <- modules, d <- m.docs, do: m.id <> "." <> d.id
    project_modules = modules |> Enum.map(&module_to_string/1) |> Enum.uniq
    Enum.map modules, &(&1 |> all_docs(project_funs, project_modules) |> all_typespecs(aliases))
  end

  defp module_to_string(module) do
    inspect module.module
  end

  defp all_docs(module, project_funs, modules) do
    locals = Enum.map module.docs, &(&1.id)

    if moduledoc = module.moduledoc do
      moduledoc = moduledoc |> local_doc(locals) |> project_doc(project_funs, modules)
    end

    docs = for node <- module.docs do
      if doc = node.doc do
        doc = doc |> local_doc(locals) |> project_doc(project_funs, modules)
      end
      %{node | doc: doc}
    end

    typedocs = for node <- module.typespecs do
      if doc = node.doc do
        doc = doc |> local_doc(locals) |> project_doc(project_funs, modules)
      end
      %{node | doc: doc}
    end

    %{module | moduledoc: moduledoc, docs: docs, typespecs: typedocs}
  end


  defp all_typespecs(module, aliases) do
    locals = Enum.map module.typespecs, fn
      %ExDoc.TypeNode{name: name, arity: arity} -> { name, arity }
    end

    typespecs = for typespec <- module.typespecs do
      %{typespec | spec: typespec(typespec.spec, locals, aliases)}
    end

    docs = for node <- module.docs do
      %{node | specs: Enum.map(node.specs, &typespec(&1, locals, aliases))}
    end

    %{module | typespecs: typespecs, docs: docs}
  end

  @doc """
  Converts the given `ast` to string while linking the locals
  given by `typespecs` as HTML.
  """
  def typespec(ast, typespecs, aliases) do
    Macro.to_string(ast, fn
      { name, _, args }, string when is_atom(name) and is_list(args) ->
        string = strip_parens(string, args)
        arity = length(args)
        if { name, arity } in typespecs do
          ~s[<a href="#t:#{name}/#{arity}">#{string}</a>]
        else
          string
        end
      { { :., _, [alias, name] }, _, args }, string when is_atom(name) and is_list(args) ->
        string = strip_parens(string, args)
        alias = expand_alias(alias)
        if source = get_source(alias, aliases) do
          ~s[<a href="#{source}#{inspect alias}.html#t:#{name}/#{length(args)}">#{string}</a>]
        else
          string
        end
      _, string ->
        string
    end)
  end

  defp strip_parens(string, []) do
    if :binary.last(string) == ?) do
      :binary.part(string, 0, byte_size(string)-2)
    else
      string
    end
  end

  defp strip_parens(string, _), do: string

  defp expand_alias({ :__aliases__, _, [h|t] }) when is_atom(h), do: Module.concat([h|t])
  defp expand_alias(atom) when is_atom(atom), do: atom
  defp expand_alias(_), do: nil

  defp get_source(alias, aliases) do
    cond do
      is_nil(alias) -> nil
      alias in aliases -> ""
      dir = from_elixir(alias) -> @elixir_docs <> dir <> "/"
      true -> nil
    end
  end

  defp from_elixir(alias) do
    alias_ebin = alias_ebin(alias)
    if String.starts_with?(alias_ebin, elixir_ebin()) do
      alias_ebin |> Path.dirname |> Path.dirname |> Path.basename
    end
  end

  defp alias_ebin(alias) do
    case :code.where_is_file('#{alias}.beam') do
      :non_existing -> ""
      path -> List.to_string(path)
    end
  end

  defp elixir_ebin do
    case :code.where_is_file('Elixir.Kernel.beam') do
      :non_existing -> [0]
      path -> path |> Path.dirname |> Path.dirname |> Path.dirname
    end
  end

  @doc """
  Create links to locally defined functions, specified in `locals`
  as a list of `fun/arity` strings.

  Ignores functions which are already wrapped in markdown url syntax,
  e.g. `[test/1](url)`. If the function doesn't touch the leading
  or trailing `]`, e.g. `[my link link/1 is here](url)`, the fun/arity
  will get translated to the new href of the function.
  """
  def local_doc(bin, locals) when is_binary(bin) do
    Regex.scan(~r{(?<!\[)`\s*(([a-z_!\\?>\\|=&<!~+\\.\\+*^@-]+)/\d+)\s*`(?!\])}, bin)
    |> Enum.uniq
    |> List.flatten
    |> Enum.filter(&(&1 in locals))
    |> Enum.reduce(bin, fn (x, acc) ->
         escaped = Regex.escape(x)
         Regex.replace(~r/(?<!\[)`(\s*(#{escaped})\s*)`(?!\])/, acc, "[`\\1`](#\\2)")
       end)
  end

  @doc """
  Creates links to modules and functions defined in the project.
  """
  def project_doc(bin, project_funs, modules) when is_binary(bin) do
    bin |> project_functions(project_funs) |> project_modules(modules) |> erlang_functions
  end

  @doc """
  Create links to functions defined in the project, specified in `project_funs`
  as a list of `Module.fun/arity` tuples.

  Ignores functions which are already wrapped in markdown url syntax,
  e.g. `[Module.test/1](url)`. If the function doesn't touch the leading
  or trailing `]`, e.g. `[my link Module.link/1 is here](url)`, the Module.fun/arity
  will get translated to the new href of the function.
  """
  def project_functions(bin, project_funs) when is_binary(bin) do
    Regex.scan(~r{(?<!\[)`\s*((([A-Z][A-Za-z]+)\.)+([a-z_!\?>\|=&<!~+\.\+*^@-]+)/\d+)\s*`(?!\])}, bin)
    |> Enum.uniq
    |> List.flatten
    |> Enum.filter(&(&1 in project_funs))
    |> Enum.reduce(bin, fn (x, acc) ->
         { mod_str, function_name, arity } = split_function(x)
         escaped = Regex.escape(x)
         Regex.replace(~r/(?<!\[)`(\s*#{escaped}\s*)`(?!\])/, acc,
           "[`\\1`](#{mod_str}.html##{function_name}/#{arity})")
       end)
  end

  @doc """
  Create links to modules defined in the project, specified in `modules`
  as a list.

  Ignores modules which are already wrapped in markdown url syntax,
  e.g. `[Module](url)`. If the module name doesn't touch the leading
  or trailing `]`, e.g. `[my link Module is here](url)`, the Module
  will get translated to the new href of the module.
  """
  def project_modules(bin, modules) when is_binary(bin) do
    Regex.scan(~r{(?<!\[)`\s*(([A-Z][A-Za-z]+\.?)+)\s*`(?!\])}, bin)
    |> Enum.uniq
    |> List.flatten
    |> Enum.filter(&(&1 in modules))
    |> Enum.reduce(bin, fn (x, acc) ->
         escaped = Regex.escape(x)
         Regex.replace(~r/(?<!\[)`(\s*#{escaped}\s*)`(?!\])/, acc,
           "[`\\1`](\\1.html)")
       end)
  end

  defp split_function(bin) do
    [modules, arity] = String.split(bin, "/")
    { mod, name } = modules
      |> String.replace(~r{([^\.])\.}, "\\1 ") # this handles the case of the ".." function
      |> String.split(" ")
      |> Enum.split(-1)
    { Enum.join(mod, "."), hd(name), arity }
  end

  @doc """
  Create links to Erlang functions in code blocks.

  Only links modules that are in the Erlang distribution `lib_dir`
  and only link functions in those modules that export a function of the
  same name and arity.

  Ignores functions which are already wrapped in markdown url syntax,
  e.g. `[:module.test/1](url)`. If the function doesn't touch the leading
  or trailing `]`, e.g. `[my link :module.link/1 is here](url)`, the :module.fun/arity
  will get translated to the new href of the function.
  """
  def erlang_functions(bin) when is_binary(bin) do
    lib_dir = erlang_lib_dir()
    Regex.scan(~r{(?<!\[)`\s*:([a-z_]+\.[0-9a-zA-Z_!\\?]+/\d+)\s*`(?!\])}, bin)
    |> Enum.uniq
    |> List.flatten
    |> Enum.filter(&valid_erlang_beam?(&1, lib_dir))
    |> Enum.filter(&module_exports_function?/1)
    |> Enum.reduce(bin, fn (x, acc) ->
         { mod_str, function_name, arity } = split_function(x)
         escaped = Regex.escape(x)
         Regex.replace(~r/(?<!\[)`(\s*:#{escaped}\s*)`(?!\])/, acc,
           "[`\\1`](#{@erlang_docs}#{mod_str}.html##{function_name}-#{arity})")
       end)
  end

  defp valid_erlang_beam?(function_str, lib_dir) do
    { mod_str, _function_name, _arity } = split_function(function_str)
    '#{mod_str}.beam'
    |> :code.where_is_file
    |> on_lib_path?(lib_dir)
  end

  defp on_lib_path?(:non_existing, _base_path), do: false
  defp on_lib_path?(beam_path, base_path) do
    beam_path |> Path.expand |> String.starts_with?(base_path)
  end

  defp erlang_lib_dir do
    :code.lib_dir |> Path.expand
  end

  defp module_exports_function?(function_str) do
    { mod_str, function_name, arity_str } = split_function(function_str)
    module = String.to_atom(mod_str)
    function_name = String.to_atom(function_name)
    {arity, _} = Integer.parse(arity_str)
    exports = module.module_info(:exports)
    Enum.member? exports, {function_name, arity}
  end
end
