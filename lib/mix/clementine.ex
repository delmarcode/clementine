if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Clementine do
    @moduledoc false
    # Shared machinery for `mix clementine.install` and
    # `mix clementine.gen.agent`.
    #
    # Two rules keep both tasks idempotent and keep them from editing a
    # host's code wrongly:
    #
    #   * Never overwrite. Every file is created only when absent and every
    #     config key only when unset, so a second run (or a run after the
    #     host edited the generated code) changes nothing.
    #   * Never guess where a supervision child goes. Igniter's
    #     `add_new_child/3` puts a child first when it has no placement,
    #     lands one item past its `after:` anchor, and falls back to the
    #     head of the first list when the anchor sits in a list joined with
    #     `++`. `add_child/4` here finds the anchor in whatever list holds
    #     it and inserts right beside it, or edits nothing and says so.

    alias Igniter.Code.Common
    alias Sourceror.Zipper

    @typedoc "The names a generator renders with."
    @type context :: %{
            app_name: atom(),
            app_module: module(),
            agents: module(),
            repo: module()
          }

    @doc "The host's app name, module prefix, agents namespace, and repo."
    @spec context(Igniter.t(), keyword()) :: {:ok, context()} | {:error, Igniter.t()}
    def context(igniter, opts) do
      app_name = Igniter.Project.Application.app_name(igniter)
      app_module = Igniter.Project.Module.module_name_prefix(igniter)

      with {:ok, repo} <- repo(igniter, app_name, opts[:repo]) do
        {:ok,
         %{
           app_name: app_name,
           app_module: app_module,
           agents: Module.concat(app_module, Agents),
           repo: repo
         }}
      end
    end

    defp repo(igniter, app_name, nil) do
      case Igniter.Libs.Ecto.list_repos(igniter) do
        {_igniter, [repo | _]} ->
          {:ok, repo}

        _none ->
          {:error,
           Igniter.add_issue(igniter, """
           No Ecto repo found for #{inspect(app_name)}. Clementine's durable runtime
           stores runs in Postgres through Ecto; add a repo, or pass --repo.
           """)}
      end
    end

    defp repo(igniter, _app_name, name) do
      repo = Igniter.Project.Module.parse(name)

      case Igniter.Project.Module.module_exists(igniter, repo) do
        {true, _igniter} ->
          {:ok, repo}

        {false, _igniter} ->
          {:error, Igniter.add_issue(igniter, "Repo #{inspect(repo)} does not exist.")}
      end
    end

    @doc "Absolute path of one of Clementine's generator templates."
    @spec template(String.t()) :: Path.t()
    def template(path) do
      :clementine
      |> Application.app_dir(Path.join("priv/templates", path))
    end

    @doc """
    Renders `template` to `target` unless `target` exists. An existing file
    is the host's code now, so it is left exactly as it is.
    """
    @spec create_once(Igniter.t(), Path.t(), Path.t(), keyword()) :: Igniter.t()
    def create_once(igniter, template, target, assigns) do
      if Igniter.exists?(igniter, target) do
        igniter
      else
        Igniter.copy_template(igniter, template(template), target, assigns)
      end
    end

    @doc "The application module, if the project has one."
    @spec app_module(Igniter.t()) :: module() | nil
    def app_module(igniter) do
      case Igniter.Project.Application.app_module(igniter) do
        {module, _opts} -> module
        module -> module
      end
    end

    @doc """
    Adds `child` (source code) to the application's supervision tree,
    immediately `:before` or `:after` the list item that starts `anchor`.

    `present` names a module whose mention anywhere in the application
    module means the child is already there (the child's own module, or
    the name a `{Registry, name: ...}` child registers). Then nothing
    changes, wherever the host moved it.

    The anchor is found in any list in the module, including one joined
    with `++` or returned by a helper function. When no list item starts
    `anchor`, nothing is edited and the host gets a warning with the line
    to add by hand.
    """
    @spec add_child(Igniter.t(), String.t(), module(), {:before | :after, module()}) ::
            Igniter.t()
    def add_child(igniter, child, present, {side, anchor}) when side in [:before, :after] do
      case app_module(igniter) do
        nil ->
          Igniter.add_warning(igniter, manual_child(child, side, anchor, "no application module"))

        app ->
          {igniter, source} = find_app_source(igniter, app)

          cond do
            source == :error ->
              Igniter.add_warning(
                igniter,
                manual_child(child, side, anchor, "#{inspect(app)} not found")
              )

            mentions?(source, present) ->
              igniter

            true ->
              Igniter.Project.Module.find_and_update_module!(igniter, app, fn zipper ->
                case find_child(zipper, anchor) do
                  {:ok, anchor_zipper} ->
                    {:ok, insert_beside(anchor_zipper, side, Sourceror.parse_string!(child))}

                  :error ->
                    {:warning,
                     manual_child(
                       child,
                       side,
                       anchor,
                       "no list item in #{inspect(app)} starts #{inspect(anchor)}"
                     )}
                end
              end)
          end
      end
    end

    defp find_app_source(igniter, app) do
      case Igniter.Project.Module.find_module(igniter, app) do
        {:ok, {igniter, _source, zipper}} -> {igniter, zipper}
        {:error, igniter} -> {igniter, :error}
      end
    end

    defp insert_beside(zipper, :before, child), do: Zipper.insert_left(zipper, child)
    defp insert_beside(zipper, :after, child), do: Zipper.insert_right(zipper, child)

    defp manual_child(child, side, anchor, why) do
      """
      Clementine could not place a supervision child (#{why}).
      Add it to your application's children by hand, #{side} #{inspect(anchor)}:

          #{child}
      """
    end

    @doc "True when `module` appears as an alias anywhere under `zipper`."
    @spec mentions?(Zipper.t(), module()) :: boolean()
    def mentions?(zipper, module) do
      zipper
      |> Zipper.topmost()
      |> Common.move_to(fn z ->
        match?({:__aliases__, _, _}, z.node) and Common.nodes_equal?(z, module)
      end)
      |> case do
        {:ok, _zipper} -> true
        :error -> false
      end
    end

    @doc """
    True when the module under `zipper` declares `@behaviour behaviour`,
    by full name or through an alias.
    """
    @spec implements?(Zipper.t(), module()) :: boolean()
    def implements?(zipper, behaviour) do
      zipper
      |> Common.move_to(fn z ->
        case z.node do
          {:@, _, [{:behaviour, _, [_arg]}]} ->
            z |> Zipper.down() |> Zipper.down() |> Common.nodes_equal?(behaviour)

          _other ->
            false
        end
      end)
      |> case do
        {:ok, _zipper} -> true
        :error -> false
      end
    end

    @doc """
    Moves to the list item that starts `module`: `module` itself or a
    `{module, args}` tuple, in any list literal.
    """
    @spec find_child(Zipper.t(), module()) :: {:ok, Zipper.t()} | :error
    def find_child(zipper, module) do
      Common.move_to(zipper, fn z -> list_item?(z) and starts?(z, module) end)
    end

    defp list_item?(zipper) do
      case Zipper.up(zipper) do
        %Zipper{node: parent} when is_list(parent) -> true
        _other -> false
      end
    end

    defp starts?(zipper, module) do
      head =
        if Igniter.Code.Tuple.tuple?(zipper) do
          case Igniter.Code.Tuple.tuple_elem(zipper, 0) do
            {:ok, elem} -> elem
            :error -> nil
          end
        else
          zipper
        end

      case head do
        %Zipper{node: {:__aliases__, _, _}} -> Common.nodes_equal?(head, module)
        _other -> false
      end
    end
  end
end
