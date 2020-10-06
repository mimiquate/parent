defmodule Parent do
  @moduledoc """
  Functions for implementing a parent process.

  A parent process is a process that manages the lifecycle of its children. Typically the simplest
  approach is to use higher-level abstractions, such as `Parent.Supervisor` or `Parent.GenServer`.
  The common behaviour for every parent process is implemented in this module, and therefore it is
  described in this document.

  ## Overview

  A parent process has the following properties:

    1. It traps exits and uses the `shutdown: :infinity` shutdown strategy.
    2. It keeps track of its children.
    3. It presents itself to the rest of the OTP as a supervisor, which means that generic code
       walking the supervision tree, such as OTP release handler, will also iterate the parent's
       subtree.
    4. Before terminating, it stops its children synchronously, in the reverse startup order.

  You can interact with the parent process from other processes using functions from the
  `Parent.Client` module. If you want to manipulate the parent from the inside, you can use the
  functions from this module.

  ## Initialization

  A parent process has to be initialized using `initialize/1`. This function takes the following
  initialization options:

    - `:max_restarts` and `:max_seconds` - same as with `Supervisor`, with the same defaults
    - `:registry?` - If true, the parent will manage its own ETS-based child registry. See the
      "Child discovery" section for details.

  When using higher-level abstractions, these options are typically passed throguh start functions,
  such as `Parent.Supervisor.start_link/2`.

  ## Child specification

  Child specification describes how the parent starts and manages a child. This specification if
  passed to functions such as `start_child/1`, `Parent.Client.start_child/2`, or
  `Parent.Supervisor.start_link/2` to start a child process.

  The specification is a map which is a superset of the [Supervisor child
  specifications](https://hexdocs.pm/elixir/Supervisor.html#module-child-specification). All the
  fields that are shared with `Supervisor` have the same effect.

  It's worth noting that the `:id` field is optional. If not provided, the child will be anonymous,
  and you can only manage it via its pid. Therefore, the minimum required child specification
  is `%{start: mfa_or_zero_arity_fun}`.

  Also, just like with `Supervisor`, you can provide `module | {module, arg}` when starting a
  child. See [Supervisor.child_spec/1](https://hexdocs.pm/elixir/Supervisor.html#module-child_spec-1)
  for details.

  To modify a child specification, `Parent.child_spec/2` can be used.

  ## Child restart

  The `:restart` option can have following values:

    - `:permanent` - A child is automatically restarted if it stops. This is the default value.
    - `:transient` - A child is automatically restarted only if it exits abnormally.
    - `:with_dep` - A child is restarted only if its dependency is restarted.
    - `:temporary` - A child is not automatically restarted.

  ## Maximum restart frequency

  Similarly to `Supervisor`, a parent process keeps track of the amount of restarts, and
  self-terminates if maximum threshold (defaults to 3 restarts in 5 seconds) is exceeded.

  In addition, you can provide child specific thresholds by including `:max_restarts` and
  `:max_seconds` options in child specification. Finally, note that `:max_restarts` can be set to
  `:infinity` (both for the parent and each child). This can be useful if you want to disable the
  parent global limit, and use child-specific limits.

  ## Bound children

  You can bind the lifecycle of each child to the lifecycles of its older siblings. This is roughly
  similar to the `:rest_for_one` supervisor strategy.

  For example, if you want to start two children, consumer and producer, and bind the producer's
  lifecycle to the consumer, you need the following child specifications:

      consumer_spec = %{
        id: :consumer,
        # ...
      }

      producer_spec = %{
        id: :producer,
        binds_to: [:consumer]
      }

  This will make sure that if the consumer stops, the producer is taken down as well.

  For this to work, you need to start the consumer before the producer. In other words, a child
  can only be bound to its older siblings.

  It's worth noting that bindings are transitive. If a child A is bound to the child B, which is
  in turns bound to child C, then child A also depends on child C. If child C stops, B and A will
  be stopped to.

  Finally, because of binding semantics (see Lifecycle dependency consequences), a child can only
  be bound to a sibling with the same or stronger restart option, where restart strengths can
  be defined as permanent > transient > with_dep > temporary. So for example, a permanent child
  can't be bound to a temporary child.

  ## Shutdown groups

  A shutdown group is a mechanism that roughly emulates the `:one_for_all` supervisor strategy.
  For example, to set up a two-way lifecycle dependency between the consumer and the producer, we
  can use the following specifications:

      consumer_spec = %{
        id: :consumer,
        shutdown_group: :consumer_and_producer
        # ...
      }

      producer_spec = %{
        id: :producer,
        shutdown_group: :consumer_and_producer
      }

  In this case, when any child of the group terminates, the other children will be taken down as
  well.

  All children belonging to the same shutdown group must use the same `:restart` option.

  Note that a child can be a member of some shutdown group, and bound to other older siblings.

  ## Lifecycle dependency consequences

  As has been mentioned, a lifecycle dependency means that a child is taken down when its
  dependency stops. This will happen irrespective of how the child has been stopped. Even if you
  manually stop the child using functions such as `shutdown_child/1` or
  `Parent.Client.shutdown_child/2`, the siblings bound to it will be taken down.

  In general, parent doesn't permit the state which violates binding settings. If the process A is
  bound to the process B, you can never reach the state where A is running but B isn't. Of course,
  since things are taking place concurrently, such state might briefly exists until parent
  is able to shutdown all bound processes.

  ## Restart flow

  Process restarts happen automatically, if a permanent child stops or if a transient child
  crashes. They can also happen manually, when you invoke `restart_child/1` or if you're manually
  returning terminated non-restarted children with the function `return_children/2`. In all these
  situations, the flow is the same.

  When a child stops, parent will take down all the siblings bound to it, and then attempt to
  restart the child and its non-temporary siblings. This is done by starting processes
  synchronously, one by one, in their startup order. If all processes are started successfully,
  restart has succeeded.

  If some process fails to start, the parent won't try to start younger siblings. If some of the
  successfully started children are bound to non-started siblings, they will be taken down as well.
  This happens because parent won't permit the state which doesn't conform to the binding
  requirements.

  Therefore, a restart may partially succeed, with some children not being started. In this case,
  the parent will retry to restart the remaining children.

  An attempt to restart a child which failed to restart is considered as a crash and contributes to
  the restart intensity. Thus, if a child repeatedly fails to restart, the parent will give up at
  some point, according to restart intensity settings.

  When the children are restarted, they will be started in the original startup order. The
  restarted children keep their original startup order with respect to non-restarted children. For
  example, suppose that four children are running: A, B, C, and D, and children B and D are
  restarted. If the parent process then stops, it will take the children down in the order D, C, B,
  and A.

  Finally, it's worth noting that if termination of one child causes the restart of multiple
  children, parent will treat this as a single restart event when calculating the restart frequency
  and considering possible self-termination.

  ## Child timeout

  You can optionally include the `:timeout` option in the child specification to ask the parent to
  terminate the child if it doesn't stop in the given time. In this case, the child's shutdown
  strategy is ignore, and the child will be forcefully terminated (using the `:kill` exit signal).

  A non-temporary child which timeouts will be restarted.

  ## Child discovery

  Children can be discovered by other processes using functions such as `Parent.Client.child_pid/2`,
  or `Parent.Client.children/1`. By default, these functions will perform a synchronous call into
  the parent process. This should work fine as long as the parent is not pressured by various
  events, such as frequent children stopping and starting, or some other custom logic.

  In such cases you can consider setting the `registry?` option to `true` when initializing the
  parent process. When this option is set, parent will create an ETS table which will be used by
  the discovery functions.

  In addition, parent supports maintaining the child-specific meta information. You can set this
  information by providing the `:meta` field in the child specification, update it through
  functions such as `update_child_meta/2` or `Parent.Client.update_child_meta/3`, and query it
  through `Parent.Client.child_meta/2`.

  ## Ignored child

  If a child start function returns `:ignore`, the parent assumes that the child process is not
  started. This can be useful to defer the decision about starting some processes to the latest
  possible moment.

  In this case, the parent process will treat the child as successfully started. The corresponding
  entry for the child will exist in internal data structure of the parent, and the child will be
  included in result of the functions such as `children/0`, with its pid set to `:undefined`.

  If an ignored child is bound to a started child and that child is restarted, the ignored child
  will be restarted too.

  For children which are started dynamically on-demand, this might lead to memory leaks. In such
  cases you can include `keep_ignored?: false` in the childspec to instruct the supervisor to avoid
  keeping the child entry if the start function returns `:ignore`.

  ## Building custom parent processes

  If available parent behaviours don't fit your purposes, you can consider building your own
  behaviour or a concrete parent process. In this case, the functions of this module will provide
  the necessary plumbing.

  The basic idea is presented in the following sketch:

      defp init_process do
        Parent.initialize(parent_opts)
        start_some_children()
        loop()
      end

      defp loop() do
        receive do
          msg ->
            case Parent.handle_message(msg) do
              # parent handled the message
              :ignore -> loop()

              # parent handled the message and returned some useful information
              {:stopped_children, stopped_children} -> handle_stopped_children(stopped_children)

              # not a parent message
              nil -> custom_handle_message(msg)
            end
        end
      end

  More specifically, to build a parent process you need to do the following:

  1. Invoke `initialize/0` when the process is started.
  2. Use functions such as `start_child/1` to work with child processes.
  3. When a message is received, invoke `handle_message/1` before handling the message yourself.
  4. If you receive a shutdown exit message from your parent, stop the process.
  5. Before terminating, invoke `shutdown_all/1` to stop all the children.
  6. Use `:infinity` as the shutdown strategy for the parent process, and `:supervisor` for its type.
  7. If the process is a `GenServer`, handle supervisor calls (see `supervisor_which_children/0`
     and `supervisor_count_children/0`).
  8. Implement `format_status/2` (see `Parent.GenServer` for details) where applicable.

  If the parent process is powered by a non-interactive code (e.g. `Task`), make sure
  to receive messages sent to that process, and handle them properly (see points 3 and 4).

  You can take a look at the code of `Parent.GenServer` for specific details.
  """
  require Logger

  alias Parent.{Registry, Restart, State}

  @type opts :: [option]
  @type option ::
          {:max_restarts, non_neg_integer | :infinity}
          | {:max_seconds, pos_integer}
          | {:registry?, boolean}

  @type child_spec :: %{
          :start => start,
          optional(:id) => child_id,
          optional(:modules) => [module] | :dynamic,
          optional(:type) => :worker | :supervisor,
          optional(:meta) => child_meta,
          optional(:shutdown) => shutdown,
          optional(:timeout) => pos_integer | :infinity,
          optional(:restart) => :temporary | :transient | :with_dep | :permanent,
          optional(:max_restarts) => non_neg_integer | :infinity,
          optional(:max_seconds) => pos_integer,
          optional(:binds_to) => [child_ref],
          optional(:shutdown_group) => shutdown_group,
          optional(:keep_ignored?) => boolean
        }

  @type child_id :: term
  @type child_meta :: term
  @type shutdown_group :: term

  @type child_ref :: child_id | pid

  @type start :: (() -> Supervisor.on_start_child()) | {module, atom, [term]}

  @type shutdown :: non_neg_integer | :infinity | :brutal_kill

  @type start_spec :: child_spec | module | {module, term}

  @type child :: %{id: child_id, pid: pid, meta: child_meta}

  @type handle_message_response ::
          {:stopped_children, stopped_children}
          | :ignore

  @type stopped_children :: %{
          child_id => %{
            optional(atom) => any,
            pid: pid,
            meta: child_meta,
            exit_reason: term
          }
        }

  @type restart_opts :: [include_temporary?: boolean]

  @type on_start_child :: Supervisor.on_start_child() | {:error, start_error}
  @type start_error ::
          :invalid_child_id
          | {:missing_deps, [child_ref]}
          | {:forbidden_bindings, from: child_id | nil, to: [child_ref]}
          | {:non_uniform_shutdown_group, [shutdown_group]}

  @spec child_spec(start_spec, Keyword.t() | child_spec) :: child_spec
  def child_spec(spec, overrides \\ []) do
    spec
    |> expand_child_spec()
    |> Map.merge(Map.new(overrides))
  end

  @spec parent_spec(Keyword.t() | child_spec) :: child_spec
  def parent_spec(overrides \\ []),
    do: Map.merge(%{shutdown: :infinity, type: :supervisor}, Map.new(overrides))

  @doc """
  Initializes the state of the parent process.

  This function should be invoked once inside the parent process before other functions from this
  module are used. If a parent behaviour, such as `Parent.GenServer`, is used, this function must
  not be invoked.
  """
  @spec initialize(opts) :: :ok
  def initialize(opts \\ []) do
    if initialized?(), do: raise("Parent state is already initialized")
    Process.flag(:trap_exit, true)
    if Keyword.get(opts, :registry?, false), do: Registry.initialize()
    store(State.initialize(opts))
  end

  @doc "Returns true if the parent state is initialized."
  @spec initialized?() :: boolean
  def initialized?(), do: not is_nil(Process.get(__MODULE__))

  @doc "Starts the child described by the specification."
  @spec start_child(start_spec) :: on_start_child()
  def start_child(child_spec) do
    state = state()
    child_spec = expand_child_spec(child_spec)

    with {:ok, pid, timer_ref} <- start_child_process(state, child_spec) do
      if pid != :undefined or child_spec.keep_ignored?,
        do: store(State.register_child(state, pid, child_spec, timer_ref))

      {:ok, pid}
    end
  end

  @doc """
  Synchronously starts all children.

  If some child fails to start, all of the children will be taken down and the parent process
  will exit.
  """
  @spec start_all_children!([start_spec()]) :: [pid | :undefined]
  def start_all_children!(child_specs) do
    Enum.map(
      child_specs,
      fn child_spec ->
        case start_child(child_spec) do
          {:ok, pid} ->
            pid

          {:error, error} ->
            msg = "Error starting the child #{inspect(child_spec.id)}: #{inspect(error)}"
            give_up!(state(), :start_error, msg)
        end
      end
    )
  end

  @doc """
  Restarts the child.

  This function will also restart all siblings which are bound to this child, including temporary
  children. You can change this behaviour by passing `include_temporary?: false`.

  The function might partially succeed if some non-temporary children fail to start. In this case
  the resulting `stopped_children` map will contain the corresponding entries. You can pass this
  map to `return_children/2` to manually return such children to the parent.

  See "Restart flow" for details on restarting procedure.
  """
  @spec restart_child(child_ref, restart_opts) :: {:ok, stopped_children} | :error
  def restart_child(child_ref, opts \\ []) do
    with {:ok, children, state} <- State.pop_child_with_bound_siblings(state(), child_ref) do
      opts = Keyword.merge([include_temporary?: true], opts)
      stop_children(children, :shutdown)
      children = Enum.map(children, &Map.put(&1, :force_restart?, &1.spec.id == child_ref))
      {stopped_children, state} = Restart.perform(state, children, opts)
      store(state)
      {:ok, stopped_children}
    end
  end

  @doc """
  Starts new instances of stopped children.

  This function can be invoked to return stopped children back to the parent. Essentially, this
  function behaves almost the same as automatic restart, with a difference that temporary children
  are by default also returned. You can change this behaviour by passing `include_temporary?:
  false`.

  The `stopped_children` information is obtained via functions such as `shutdown_child/1` or
  `shutdown_all/1`. In addition, Parent will provide this info via `handle_message/1`  when some
  children are terminated and not returned to the parent.
  """
  @spec return_children(stopped_children, restart_opts) :: stopped_children
  def return_children(stopped_children, opts \\ []) do
    opts = Keyword.merge([include_temporary?: true], opts)
    {stopped_children, state} = Restart.perform(state(), Map.values(stopped_children), opts)
    store(state)
    stopped_children
  end

  @doc """
  Terminates the child.

  This function will also shut down all siblings directly and transitively bound to the given child.
  The function will wait for the child to terminate, and pull the `:EXIT` message from the mailbox.

  Permanent and transient children won't be restarted, and their specifications won't be preserved.
  In other words, this function completely removes the child and all other children bound to it.
  """
  @spec shutdown_child(child_ref) :: {:ok, stopped_children} | :error
  def shutdown_child(child_ref) do
    with {:ok, children, state} <- State.pop_child_with_bound_siblings(state(), child_ref) do
      stop_children(children, :shutdown)
      store(state)
      {:ok, stopped_children(children)}
    end
  end

  @doc """
  Terminates all running child processes.

  Children are terminated synchronously, in the reverse order from the order they
  have been started in. All corresponding `:EXIT` messages will be pulled from the mailbox.
  """
  @spec shutdown_all(term) :: stopped_children
  def shutdown_all(reason \\ :shutdown) do
    state = state()
    children = State.children(state)
    stop_children(children, with(:normal <- reason, do: :shutdown))
    store(State.reinitialize(state))
    stopped_children(children)
  end

  @doc """
  Should be invoked by the parent process for each incoming message.

  If the given message is not handled, this function returns `nil`. In such cases, the client code
  should perform standard message handling. Otherwise, the message has been handled by the parent,
  and the client code shouldn't treat this message as a standard message (e.g. by calling
  `handle_info` of the callback module).

  If `:ignore` is returned, the message has been processed, and the client code should ignore it.
  Finally, if the return value is `{:stopped_children, info}`, it indicates that a child process
  has terminated. A client may do some extra processing in this case.

  Note that you don't need to invoke this function in a `Parent.GenServer` callback module.
  """
  @spec handle_message(term) :: handle_message_response() | nil
  def handle_message({:"$parent_call", client, {Parent.Client, message}}) do
    GenServer.reply(client, Parent.Client.handle_request(message))
    :ignore
  end

  def handle_message(message) do
    with {result, state} <- do_handle_message(state(), message) do
      store(state)
      result
    end
  end

  @doc "Returns the list of running child processes in the startup order."
  @spec children :: [child]
  def children() do
    state()
    |> State.children()
    |> Enum.sort_by(& &1.startup_index)
    |> Enum.map(&%{id: &1.spec.id, pid: &1.pid, meta: &1.meta})
  end

  @doc """
  Returns true if the child process is still running, false otherwise.

  Note that this function might return true even if the child has terminated.
  This can happen if the corresponding `:EXIT` message still hasn't been
  processed.
  """
  @spec child?(child_ref) :: boolean
  def child?(child_ref), do: match?({:ok, _}, State.child(state(), child_ref))

  @doc """
  Should be invoked by the behaviour when handling `:which_children` GenServer call.

  You only need to invoke this function if you're implementing a parent process using a behaviour
  which forwards `GenServer` call messages to the `handle_call` callback. In such cases you need
  to respond to the client with the result of this function. Note that parent behaviours such as
  `Parent.GenServer` will do this automatically.

  If no translation of `GenServer` messages is taking place, i.e. if you're handling all messages
  in their original shape, this function will be invoked through `handle_message/1`.
  """
  @spec supervisor_which_children() :: [{term(), pid(), :worker, [module()] | :dynamic}]
  def supervisor_which_children() do
    state()
    |> State.children()
    |> Enum.map(&{&1.spec.id || :undefined, &1.pid, &1.spec.type, &1.spec.modules})
  end

  @doc """
  Should be invoked by the behaviour when handling `:count_children` GenServer call.

  See `supervisor_which_children/0` for details.
  """
  @spec supervisor_count_children() :: [
          specs: non_neg_integer,
          active: non_neg_integer,
          supervisors: non_neg_integer,
          workers: non_neg_integer
        ]
  def supervisor_count_children() do
    Enum.reduce(
      State.children(state()),
      %{specs: 0, active: 0, supervisors: 0, workers: 0},
      fn child, acc ->
        %{
          acc
          | specs: acc.specs + 1,
            active: acc.active + 1,
            workers: acc.workers + if(child.spec.type == :worker, do: 1, else: 0),
            supervisors: acc.supervisors + if(child.spec.type == :supervisor, do: 1, else: 0)
        }
      end
    )
    |> Map.to_list()
  end

  @doc """
  Should be invoked by the behaviour when handling `:get_childspec` GenServer call.

  See `:supervisor.get_childspec/2` for details.
  """
  @spec supervisor_get_childspec(child_ref) :: {:ok, child_spec} | {:error, :not_found}
  def supervisor_get_childspec(child_ref) do
    case State.child(state(), child_ref) do
      {:ok, child} -> {:ok, child.spec}
      :error -> {:error, :not_found}
    end
  end

  @doc "Returns the count of running child processes."
  @spec num_children() :: non_neg_integer
  def num_children(), do: State.num_children(state())

  @doc "Returns the id of a child process with the given pid."
  @spec child_id(pid) :: {:ok, child_id} | :error
  def child_id(child_pid), do: State.child_id(state(), child_pid)

  @doc "Returns the pid of a child process with the given id."
  @spec child_pid(child_id) :: {:ok, pid} | :error
  def child_pid(child_id), do: State.child_pid(state(), child_id)

  @doc "Returns the meta associated with the given child id."
  @spec child_meta(child_ref) :: {:ok, child_meta} | :error
  def child_meta(child_ref), do: State.child_meta(state(), child_ref)

  @doc "Updates the meta of the given child process."
  @spec update_child_meta(child_ref, (child_meta -> child_meta)) :: :ok | :error
  def update_child_meta(child_ref, updater) do
    with {:ok, meta, new_state} <- State.update_child_meta(state(), child_ref, updater) do
      if State.registry?(new_state), do: Registry.update_meta(child_ref, meta)
      store(new_state)
    end
  end

  defp expand_child_spec(mod) when is_atom(mod), do: expand_child_spec({mod, []})
  defp expand_child_spec({mod, arg}), do: expand_child_spec(mod.child_spec(arg))

  defp expand_child_spec(%{} = child_spec) do
    default_spec()
    |> Map.merge(default_type_and_shutdown_spec(Map.get(child_spec, :type, :worker)))
    |> Map.put(:modules, default_modules(child_spec.start))
    |> Map.merge(child_spec)
  end

  defp expand_child_spec(_other), do: raise("invalid child_spec")

  defp default_spec do
    %{
      id: nil,
      meta: nil,
      timeout: :infinity,
      restart: :permanent,
      max_restarts: :infinity,
      max_seconds: :timer.seconds(5),
      binds_to: [],
      shutdown_group: nil,
      keep_ignored?: true
    }
  end

  defp default_type_and_shutdown_spec(:worker), do: %{type: :worker, shutdown: :timer.seconds(5)}
  defp default_type_and_shutdown_spec(:supervisor), do: %{type: :supervisor, shutdown: :infinity}

  defp default_modules({mod, _fun, _args}), do: [mod]

  defp default_modules(fun) when is_function(fun),
    do: [fun |> :erlang.fun_info() |> Keyword.fetch!(:module)]

  @doc false
  def start_child_process(state, child_spec) do
    with :ok <- validate_spec(state, child_spec) do
      case invoke_start_function(child_spec.start) do
        :ignore ->
          {:ok, :undefined, nil}

        {:ok, pid} ->
          timer_ref =
            case child_spec.timeout do
              :infinity -> nil
              timeout -> Process.send_after(self(), {__MODULE__, :child_timeout, pid}, timeout)
            end

          if State.registry?(state), do: Registry.register(pid, child_spec)

          {:ok, pid, timer_ref}

        error ->
          error
      end
    end
  end

  defp validate_spec(state, child_spec) do
    with :ok <- check_id_type(child_spec.id),
         :ok <- check_id_uniqueness(state, child_spec.id),
         :ok <- check_missing_deps(state, child_spec),
         :ok <- check_valid_bindings(state, child_spec),
         do: check_valid_shutdown_group(state, child_spec)
  end

  defp check_id_type(pid) when is_pid(pid), do: {:error, :invalid_child_id}
  defp check_id_type(_other), do: :ok

  defp check_id_uniqueness(state, id) do
    case State.child_pid(state, id) do
      {:ok, pid} -> {:error, {:already_started, pid}}
      :error -> :ok
    end
  end

  defp check_missing_deps(state, child_spec) do
    case Enum.reject(child_spec.binds_to, &State.child?(state, &1)) do
      [] -> :ok
      missing_deps -> {:error, {:missing_deps, missing_deps}}
    end
  end

  defp check_valid_bindings(state, %{restart: from} = child_spec) do
    child_spec.binds_to
    |> Enum.map(&State.child!(state, &1))
    |> Enum.reject(fn %{spec: %{restart: to}} ->
      # Valid bindings:
      #
      # 1. A child can bind to a dep with the same restart strategy
      # 2. Transient child can bind to a permanent child
      # 3. with_dep child can bind to a transient and a permanent child
      # 4. Temporary child can bind to everyone

      from == to or
        (from == :transient and to == :permanent) or
        (from == :with_dep and to in ~w/transient permanent/a) or
        from == :temporary
    end)
    |> Enum.map(&with nil <- &1.spec.id, do: &1.spec.pid)
    |> case do
      [] -> :ok
      deps -> {:error, {:forbidden_bindings, from: child_spec.id, to: deps}}
    end
  end

  defp check_valid_shutdown_group(_state, %{shutdown_group: nil}), do: :ok

  defp check_valid_shutdown_group(state, child_spec) do
    state
    |> State.children_in_shutdown_group(child_spec.shutdown_group)
    |> Stream.map(& &1.spec)
    |> Stream.concat([child_spec])
    |> Stream.map(& &1.restart)
    |> Enum.uniq()
    |> case do
      [_] -> :ok
      [_ | _] -> {:error, {:non_uniform_shutdown_group, child_spec.shutdown_group}}
    end
  end

  defp invoke_start_function({mod, fun, args}), do: apply(mod, fun, args)
  defp invoke_start_function(fun) when is_function(fun, 0), do: fun.()

  defp do_handle_message(state, {:EXIT, pid, reason}) do
    case State.child(state, pid) do
      {:ok, child} ->
        kill_timer(child.timer_ref, pid)
        handle_child_down(state, child, reason)

      :error ->
        nil
    end
  end

  defp do_handle_message(state, {__MODULE__, :child_timeout, pid}) do
    child = State.child!(state, pid)
    stop_child(child, :kill)
    handle_child_down(state, child, :timeout)
  end

  defp do_handle_message(state, {__MODULE__, :resume_restart, stopped_children}),
    do: auto_restart(state, stopped_children)

  defp do_handle_message(state, {:"$gen_call", client, :which_children}) do
    GenServer.reply(client, supervisor_which_children())
    {:ignore, state}
  end

  defp do_handle_message(state, {:"$gen_call", client, :count_children}) do
    GenServer.reply(client, supervisor_count_children())
    {:ignore, state}
  end

  defp do_handle_message(state, {:"$gen_call", client, {:get_childspec, child_ref}}) do
    GenServer.reply(client, supervisor_get_childspec(child_ref))
    {:ignore, state}
  end

  defp do_handle_message(_state, _other), do: nil

  defp handle_child_down(state, child, reason) do
    if State.registry?(state), do: Registry.unregister(child.pid)
    {:ok, children, state} = State.pop_child_with_bound_siblings(state, child.pid)
    child = Map.merge(child, %{record_restart?: true, exit_reason: reason})

    bound_siblings =
      children
      |> Stream.reject(&(&1.spec.id == child.spec.id))
      |> Enum.map(&Map.put(&1, :exit_reason, :shutdown))

    stop_children(bound_siblings, :shutdown)
    stopped_children = stopped_children([child | bound_siblings])

    if child.spec.restart == :permanent or
         (child.spec.restart == :transient and reason != :normal),
       do: auto_restart(state, stopped_children),
       else: {{:stopped_children, stopped_children}, state}
  end

  defp auto_restart(state, stopped_children) do
    {stopped_children, state} = Restart.perform(state, Map.values(stopped_children))

    if map_size(stopped_children) == 0,
      # all children successfully returned
      do: {:ignore, state},
      else: {{:stopped_children, stopped_children}, state}
  end

  @doc false
  def stopped_children(children),
    do: Enum.into(children, %{}, &{with(nil <- &1.spec.id, do: &1.pid), &1})

  @doc false
  def give_up!(state, exit, error) do
    Logger.error(error)
    store(state)
    shutdown_all()
    exit(exit)
  end

  @doc false
  def stop_children(children, reason) do
    children
    |> Enum.sort_by(& &1.startup_index, :desc)
    |> Enum.each(&stop_child(&1, reason))
  end

  defp stop_child(child, reason) do
    kill_timer(child.timer_ref, child.pid)
    exit_signal = if child.spec.shutdown == :brutal_kill, do: :kill, else: reason
    wait_time = if exit_signal == :kill, do: :infinity, else: child.spec.shutdown
    sync_stop_process(child.pid, exit_signal, wait_time)
    if State.registry?(state()), do: Registry.unregister(child.pid)
  end

  defp sync_stop_process(:undefined, _exit_signal, _wait_time), do: :ok

  defp sync_stop_process(pid, exit_signal, wait_time) do
    # Using monitors to detect process termination. In most cases links would suffice, but
    # monitors can help us deal with a child which unlinked itself from the parent.
    mref = Process.monitor(pid)
    Process.exit(pid, exit_signal)

    # TODO: we should check the reason and log an error if it's not `exit_signal` (or :killed in
    # the second receive).
    receive do
      {:DOWN, ^mref, :process, ^pid, _reason} -> :ok
    after
      wait_time ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^mref, :process, ^pid, _reason} -> :ok
        end
    end

    # cleanup the exit signal
    receive do
      {:EXIT, ^pid, _reason} -> :ok
    after
      # timeout 0 is fine b/c exit signals are sent before monitors
      0 ->
        # if we end up here, the child has unlinked itself
        :ok
    end
  end

  defp kill_timer(nil, _pid), do: :ok

  defp kill_timer(timer_ref, pid) do
    Process.cancel_timer(timer_ref)

    receive do
      {Parent, :child_timeout, ^pid} -> :ok
    after
      0 -> :ok
    end
  end

  @spec state() :: State.t()
  defp state() do
    state = Process.get(__MODULE__)
    if is_nil(state), do: raise("Parent is not initialized")
    state
  end

  @spec store(State.t()) :: :ok
  defp store(state) do
    Process.put(__MODULE__, state)
    :ok
  end
end
