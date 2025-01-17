defmodule Axon.Compiler do
  @moduledoc false

  import Axon.Shared

  ## Init JIT Compilation

  @doc false
  def __compile__(graph) do
    {compile_init(graph), compile_predict(graph)}
  end

  @doc false
  def __jit_init__(graph, caller, [] = args, opts) do
    fun = compile_init(graph)
    jit_or_apply(caller, fun, args, opts)
  end

  defp compile_init(graph) when is_tuple(graph) do
    fn ->
      graph
      |> Tuple.to_list()
      |> Enum.reduce(%{}, &to_init_fun/2)
      |> Map.new(fn {k, v} -> {k, v.()} end)
    end
  end

  defp compile_init(%Axon{} = graph) do
    fn ->
      graph
      |> to_init_fun(%{})
      |> Map.new(fn {k, v} -> {k, v.()} end)
    end
  end

  defp to_init_fun(%Axon{parent: parents}, cache) when is_list(parents) do
    Enum.reduce(parents, cache, &to_init_fun/2)
  end

  defp to_init_fun(%Axon{parent: parent, params: params, opts: opts}, cache) do
    cache =
      case opts[:hidden_state] do
        state when is_tuple(state) ->
          state
          |> Tuple.to_list()
          |> Enum.reduce(cache, &to_init_fun/2)

        nil ->
          cache
      end

    cache =
      Enum.reduce(params, cache, fn
        {_, %{name: name} = param}, cache ->
          case cache do
            %{^name => _} ->
              cache

            %{} ->
              %{name: name, shape: shape, initializer: initializer} = param
              fun = fn -> apply(Axon.Initializers, initializer, [[shape: shape]]) end
              Map.put(cache, name, fun)
          end
      end)

    if parent do
      to_init_fun(parent, cache)
    else
      cache
    end
  end

  ## Model JIT Compilation

  @doc false
  def __jit_predict__(graph, caller, args, opts) do
    fun = compile_predict(graph)
    jit_or_apply(caller, fun, args, opts)
  end

  defp compile_predict(graph) when is_tuple(graph) do
    graph = Tuple.to_list(graph)

    input_ids =
      Enum.reduce(graph, [], fn x, input_ids ->
        get_inputs(x, input_ids)
      end)

    input_map =
      input_ids
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.with_index()
      |> Enum.into(%{})

    fn params, inputs ->
      {funs, _} = Enum.map_reduce(graph, %{}, &to_predict_fun(&1, &2, input_map))

      funs
      |> Enum.reverse()
      |> Enum.map(& &1.(params, inputs))
      |> List.to_tuple()
    end
  end

  defp compile_predict(%Axon{} = graph) do
    input_ids = get_inputs(graph, [])

    input_map =
      input_ids
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.with_index()
      |> Enum.into(%{})

    fn params, inputs ->
      {fun, _} = to_predict_fun(graph, %{}, input_map)
      fun.(params, inputs)
    end
  end

  ## Input Ordering

  defp get_inputs(%Axon{id: id, op: :input}, input_ids) do
    [id | input_ids]
  end

  defp get_inputs(%Axon{parent: parents}, input_ids)
       when is_list(parents) do
    Enum.reduce(parents, input_ids, fn graph, input_ids ->
      get_inputs(graph, input_ids)
    end)
  end

  defp get_inputs(%Axon{parent: parent, opts: opts}, input_ids) do
    input_ids =
      case opts[:hidden_state] do
        state when is_tuple(state) ->
          state
          |> Tuple.to_list()
          |> Enum.reduce(input_ids, fn graph, input_ids ->
            get_inputs(graph, input_ids)
          end)

        nil ->
          input_ids
      end

    get_inputs(parent, input_ids)
  end

  defp to_predict_fun(%{id: id} = graph, cache, input_map) do
    case cache do
      %{^id => fun} ->
        {fun, cache}

      %{} ->
        {fun, cache} = recur_predict_fun(graph, cache, input_map)
        cache = Map.put(cache, id, fun)
        {fun, cache}
    end
  end

  ## Custom Layers
  defp recur_predict_fun(
         %Axon{op: op, parent: parent, params: layer_params, opts: opts},
         cache,
         input_map
       )
       when is_function(op) do
    {fun, cache} = to_predict_fun(parent, cache, input_map)

    fun = fn params, input ->
      inp_params =
        Map.new(layer_params, fn {k, %{name: v, frozen: frz}} ->
          {k, maybe_freeze(params[v], frz)}
        end)

      apply(op, [fun.(params, input) | [inp_params] ++ opts])
    end

    {fun, cache}
  end

  ## Activation Layers

  @activation_layers [:celu, :elu, :exp, :gelu, :hard_sigmoid, :hard_silu, :hard_tanh] ++
                       [:leaky_relu, :linear, :log_sigmoid, :mish, :relu, :relu6] ++
                       [:sigmoid, :silu, :selu, :softmax, :softplus, :softsign, :tanh]

  defp recur_predict_fun(%Axon{op: op, parent: parent}, cache, input_map)
       when op in @activation_layers do
    {fun, cache} = to_predict_fun(parent, cache, input_map)

    fun = fn params, inputs ->
      apply(Axon.Activations, op, [fun.(params, inputs)])
    end

    {fun, cache}
  end

  ## Linear Layers

  defp recur_predict_fun(
         %Axon{
           op: :dense,
           parent: parent,
           params: %{"kernel" => %{name: w, frozen: w_frz}, "bias" => %{name: b, frozen: b_frz}}
         },
         cache,
         input_map
       ) do
    {fun, cache} = to_predict_fun(parent, cache, input_map)

    fun = fn params, inputs ->
      w = maybe_freeze(params[w], w_frz)
      b = maybe_freeze(params[b], b_frz)
      apply(Axon.Layers, :dense, [fun.(params, inputs), w, b])
    end

    {fun, cache}
  end

  ## Pooling Layers

  @pooling_layers [:max_pool, :avg_pool, :adaptive_avg_pool, :adaptive_max_pool, :lp_pool]

  defp recur_predict_fun(%Axon{op: op, parent: parent, opts: opts}, cache, input_map)
       when op in @pooling_layers do
    {fun, cache} = to_predict_fun(parent, cache, input_map)

    fun = fn params, inputs ->
      apply(Axon.Layers, op, [fun.(params, inputs), opts])
    end

    {fun, cache}
  end

  ## Dropout Layers

  @dropout_layers [:dropout, :feature_alpha_dropout, :spatial_dropout, :alpha_dropout]

  defp recur_predict_fun(%Axon{op: op, parent: parent, opts: opts}, cache, input_map)
       when op in @dropout_layers do
    {fun, cache} = to_predict_fun(parent, cache, input_map)

    fun = fn params, inputs ->
      apply(Axon.Layers, op, [fun.(params, inputs), opts])
    end

    {fun, cache}
  end

  ## Conv Layers

  @conv_layers [:conv, :conv_transpose, :depthwise_conv]

  defp recur_predict_fun(
         %Axon{
           op: op,
           parent: parent,
           opts: opts,
           params: %{"kernel" => %{name: k, frozen: k_frz}, "bias" => %{name: b, frozen: b_frz}}
         },
         cache,
         input_map
       )
       when op in @conv_layers do
    {fun, cache} = to_predict_fun(parent, cache, input_map)

    fun = fn params, inputs ->
      k = maybe_freeze(params[k], k_frz)
      b = maybe_freeze(params[b], b_frz)
      apply(Axon.Layers, op, [fun.(params, inputs), k, b, opts])
    end

    {fun, cache}
  end

  defp recur_predict_fun(
         %Axon{
           op: :separable_conv2d,
           parent: parent,
           opts: opts,
           params: %{
             "k1" => %{name: k1, frozen: k1_frz},
             "b1" => %{name: b1, frozen: b1_frz},
             "k2" => %{name: k2, frozen: k2_frz},
             "b2" => %{name: b2, frozen: b2_frz}
           }
         },
         cache,
         input_map
       ) do
    {fun, cache} = to_predict_fun(parent, cache, input_map)

    fun = fn params, inputs ->
      k1 = maybe_freeze(params[k1], k1_frz)
      b1 = maybe_freeze(params[b1], b1_frz)
      k2 = maybe_freeze(params[k2], k2_frz)
      b2 = maybe_freeze(params[b2], b2_frz)
      apply(Axon.Layers, :separable_conv2d, [fun.(params, inputs), k1, b1, k2, b2, opts])
    end

    {fun, cache}
  end

  defp recur_predict_fun(
         %Axon{
           op: :separable_conv2d,
           parent: parent,
           opts: opts,
           params: %{
             "k1" => %{name: k1, frozen: k1_frz},
             "b1" => %{name: b1, frozen: b1_frz},
             "k2" => %{name: k2, frozen: k2_frz},
             "b2" => %{name: b2, frozen: b2_frz},
             "k3" => %{name: k3, frozen: k3_frz},
             "b3" => %{name: b3, frozen: b3_frz}
           }
         },
         cache,
         input_map
       ) do
    {fun, cache} = to_predict_fun(parent, cache, input_map)

    fun = fn params, inputs ->
      k1 = maybe_freeze(params[k1], k1_frz)
      b1 = maybe_freeze(params[b1], b1_frz)
      k2 = maybe_freeze(params[k2], k2_frz)
      b2 = maybe_freeze(params[b2], b2_frz)
      k3 = maybe_freeze(params[k3], k3_frz)
      b3 = maybe_freeze(params[b3], b3_frz)
      apply(Axon.Layers, :separable_conv3d, [fun.(params, inputs), k1, b1, k2, b2, k3, b3, opts])
    end

    {fun, cache}
  end

  ## Normalization Layers

  @normalization_layers [:batch_norm, :layer_norm, :group_norm, :instance_norm]

  defp recur_predict_fun(
         %Axon{
           op: op,
           parent: parent,
           opts: opts,
           params: %{"gamma" => %{name: g, frozen: g_frz}, "beta" => %{name: b, frozen: b_frz}}
         },
         cache,
         input_map
       )
       when op in @normalization_layers do
    {fun, cache} = to_predict_fun(parent, cache, input_map)

    fun = fn params, inputs ->
      g = maybe_freeze(params[g], g_frz)
      b = maybe_freeze(params[b], b_frz)
      apply(Axon.Layers, op, [fun.(params, inputs), g, b, opts])
    end

    {fun, cache}
  end

  ## Recurrent Layers

  defp recur_predict_fun(
         %Axon{
           op: :lstm,
           parent: parent,
           params: %{
             "wii" => %{name: wii, frozen: wii_frz},
             "wif" => %{name: wif, frozen: wif_frz},
             "wig" => %{name: wig, frozen: wig_frz},
             "wio" => %{name: wio, frozen: wio_frz},
             "whi" => %{name: whi, frozen: whi_frz},
             "whf" => %{name: whf, frozen: whf_frz},
             "whg" => %{name: whg, frozen: whg_frz},
             "who" => %{name: who, frozen: who_frz},
             "bi" => %{name: bi, frozen: bi_frz},
             "bf" => %{name: bf, frozen: bf_frz},
             "bg" => %{name: bg, frozen: bg_frz},
             "bo" => %{name: bo, frozen: bo_frz}
           },
           opts: [
             activation: activation,
             gate: gate,
             hidden_state: hidden_state,
             hidden_state_shape: hidden_state_shape,
             recurrent_initializer: recurrent_initializer,
             unroll: unroll
           ]
         },
         cache,
         input_map
       ) do
    {fun, cache} = to_predict_fun(parent, cache, input_map)

    fun = fn params, input ->
      input = fun.(params, input)

      hidden_state_fun =
        case hidden_state do
          {%Axon{} = c, %Axon{} = h} ->
            {c_fun, cache} = to_predict_fun(c, cache, input_map)
            {h_fun, _} = to_predict_fun(h, cache, input_map)

            fn params, inputs ->
              {c_fun.(params, inputs), h_fun.(params, inputs)}
            end

          %Axon{} = x ->
            {hidden_fun, _} = to_predict_fun(x, cache, input_map)
            hidden_fun

          nil ->
            shape = put_elem(hidden_state_shape, 0, elem(Nx.shape(input), 0))

            fn _, _ ->
              {
                apply(Axon.Initializers, recurrent_initializer, [[shape: shape]]),
                apply(Axon.Initializers, recurrent_initializer, [[shape: shape]])
              }
            end
        end

      input_kernel =
        {maybe_freeze(params[wii], wii_frz), maybe_freeze(params[wif], wif_frz),
         maybe_freeze(params[wig], wig_frz), maybe_freeze(params[wio], wio_frz)}

      hidden_kernel =
        {maybe_freeze(params[whi], whi_frz), maybe_freeze(params[whf], whf_frz),
         maybe_freeze(params[whg], whg_frz), maybe_freeze(params[who], who_frz)}

      bias =
        {maybe_freeze(params[bi], bi_frz), maybe_freeze(params[bf], bf_frz),
         maybe_freeze(params[bg], bg_frz), maybe_freeze(params[bo], bo_frz)}

      carry = hidden_state_fun.(params, input)

      gate_fn = &apply(Axon.Activations, gate, [&1])
      activation_fn = &apply(Axon.Activations, activation, [&1])

      case unroll do
        :static ->
          Axon.Recurrent.static_unroll(
            &Axon.Recurrent.lstm_cell(&1, &2, &3, &4, &5, gate_fn, activation_fn),
            fun.(params, input),
            carry,
            input_kernel,
            hidden_kernel,
            bias
          )

        :dynamic ->
          Axon.Recurrent.dynamic_unroll(
            &Axon.Recurrent.lstm_cell(&1, &2, &3, &4, &5, gate_fn, activation_fn),
            fun.(params, input),
            carry,
            input_kernel,
            hidden_kernel,
            bias
          )
      end
    end

    {fun, cache}
  end

  defp recur_predict_fun(
         %Axon{
           op: :conv_lstm,
           parent: parent,
           params: %{
             "wi" => %{name: wi, frozen: wi_frz},
             "wh" => %{name: wh, frozen: wh_frz},
             "b" => %{name: b, frozen: b_frz}
           },
           opts: [
             hidden_state: hidden_state,
             strides: strides,
             padding: padding,
             hidden_state_shape: hidden_state_shape,
             recurrent_initializer: recurrent_initializer,
             unroll: unroll
           ]
         },
         cache,
         input_map
       ) do
    {fun, cache} = to_predict_fun(parent, cache, input_map)

    fun = fn params, input ->
      input = fun.(params, input)

      hidden_state_fun =
        case hidden_state do
          {%Axon{} = c, %Axon{} = h} ->
            {c_fun, cache} = to_predict_fun(c, cache, input_map)
            {h_fun, _} = to_predict_fun(h, cache, input_map)

            fn params, inputs ->
              {c_fun.(params, inputs), h_fun.(params, inputs)}
            end

          %Axon{} = x ->
            {hidden_fun, _} = to_predict_fun(x, cache, input_map)
            hidden_fun

          nil ->
            shape = put_elem(hidden_state_shape, 0, elem(Nx.shape(input), 0))

            fn _, _ ->
              {
                apply(Axon.Initializers, recurrent_initializer, [[shape: shape]]),
                apply(Axon.Initializers, recurrent_initializer, [[shape: shape]])
              }
            end
        end

      input_kernel = {maybe_freeze(params[wi], wi_frz)}
      hidden_kernel = {maybe_freeze(params[wh], wh_frz)}
      bias = {maybe_freeze(params[b], b_frz)}

      carry = hidden_state_fun.(params, input)

      case unroll do
        :static ->
          Axon.Recurrent.static_unroll(
            &Axon.Recurrent.conv_lstm_cell(&1, &2, &3, &4, &5, strides: strides, padding: padding),
            fun.(params, input),
            carry,
            input_kernel,
            hidden_kernel,
            bias
          )

        :dynamic ->
          Axon.Recurrent.dynamic_unroll(
            &Axon.Recurrent.conv_lstm_cell(&1, &2, &3, &4, &5, strides: strides, padding: padding),
            fun.(params, input),
            carry,
            input_kernel,
            hidden_kernel,
            bias
          )
      end
    end

    {fun, cache}
  end

  defp recur_predict_fun(
         %Axon{
           op: :gru,
           parent: parent,
           params: %{
             "wir" => %{name: wir, frozen: wir_frz},
             "wiz" => %{name: wiz, frozen: wiz_frz},
             "win" => %{name: win, frozen: win_frz},
             "whr" => %{name: whr, frozen: whr_frz},
             "whz" => %{name: whz, frozen: whz_frz},
             "whn" => %{name: whn, frozen: whn_frz},
             "br" => %{name: br, frozen: br_frz},
             "bz" => %{name: bz, frozen: bz_frz},
             "bin" => %{name: bin, frozen: bin_frz},
             "bhn" => %{name: bhn, frozen: bhn_frz}
           },
           opts: [
             activation: activation,
             gate: gate,
             hidden_state: hidden_state,
             hidden_state_shape: hidden_state_shape,
             recurrent_initializer: recurrent_initializer,
             unroll: unroll
           ]
         },
         cache,
         input_map
       ) do
    {fun, cache} = to_predict_fun(parent, cache, input_map)

    fun = fn params, input ->
      input = fun.(params, input)

      hidden_state_fun =
        case hidden_state do
          {%Axon{} = c} ->
            {h_fun, _} = to_predict_fun(c, cache, input_map)

            fn params, inputs ->
              {h_fun.(params, inputs)}
            end

          %Axon{} = x ->
            {hidden_fun, _} = to_predict_fun(x, cache, input_map)
            hidden_fun

          nil ->
            shape = put_elem(hidden_state_shape, 0, elem(Nx.shape(input), 0))

            fn _, _ ->
              {
                apply(Axon.Initializers, recurrent_initializer, [[shape: shape]])
              }
            end
        end

      input_kernel =
        {maybe_freeze(params[wir], wir_frz), maybe_freeze(params[wiz], wiz_frz),
         maybe_freeze(params[win], win_frz)}

      hidden_kernel =
        {maybe_freeze(params[whr], whr_frz), maybe_freeze(params[whz], whz_frz),
         maybe_freeze(params[whn], whn_frz)}

      bias =
        {maybe_freeze(params[br], br_frz), maybe_freeze(params[bz], bz_frz),
         maybe_freeze(params[bin], bin_frz), maybe_freeze(params[bhn], bhn_frz)}

      carry = hidden_state_fun.(params, input)

      gate_fn = &apply(Axon.Activations, gate, [&1])
      activation_fn = &apply(Axon.Activations, activation, [&1])

      case unroll do
        :static ->
          Axon.Recurrent.static_unroll(
            &Axon.Recurrent.gru_cell(&1, &2, &3, &4, &5, gate_fn, activation_fn),
            fun.(params, input),
            carry,
            input_kernel,
            hidden_kernel,
            bias
          )

        :dynamic ->
          Axon.Recurrent.dynamic_unroll(
            &Axon.Recurrent.gru_cell(&1, &2, &3, &4, &5, gate_fn, activation_fn),
            fun.(params, input),
            carry,
            input_kernel,
            hidden_kernel,
            bias
          )
      end
    end

    {fun, cache}
  end

  ## Element-wise layers

  @element_wise_layers [:add, :subtract, :multiply]

  defp recur_predict_fun(%Axon{op: op, parent: parents}, cache, input_map)
       when op in @element_wise_layers do
    {[fun | funs], cache} = Enum.map_reduce(parents, cache, &recur_predict_fun(&1, &2, input_map))

    fun = fn params, inputs ->
      Enum.reduce(funs, fun.(params, inputs), fn next_fn, acc ->
        apply(Nx, op, [acc, next_fn.(params, inputs)])
      end)
    end

    {fun, cache}
  end

  ## Shape Layers

  defp recur_predict_fun(%Axon{op: :flatten, parent: parent}, cache, input_map) do
    {fun, cache} = to_predict_fun(parent, cache, input_map)

    fun = fn params, inputs ->
      apply(Axon.Layers, :flatten, [fun.(params, inputs)])
    end

    {fun, cache}
  end

  defp recur_predict_fun(
         %Axon{op: :reshape, parent: parent, output_shape: output_shape},
         cache,
         input_map
       ) do
    {fun, cache} = to_predict_fun(parent, cache, input_map)

    fun = fn params, inputs ->
      inp = fun.(params, inputs)
      reshape_shape = put_elem(output_shape, 0, elem(Nx.shape(inp), 0))
      apply(Nx, :reshape, [inp, reshape_shape])
    end

    {fun, cache}
  end

  defp recur_predict_fun(
         %Axon{op: :transpose, parent: parent, opts: [permutation: permutation]},
         cache,
         input_map
       ) do
    {fun, cache} = to_predict_fun(parent, cache, input_map)

    fun = fn params, inputs ->
      permutation = [0 | Enum.map(permutation, &(&1 + 1))]
      apply(Nx, :transpose, [fun.(params, inputs), [axes: permutation]])
    end

    {fun, cache}
  end

  defp recur_predict_fun(
         %Axon{op: :pad, parent: parent, opts: [padding_config: config, value: value]},
         cache,
         input_map
       ) do
    {fun, cache} = to_predict_fun(parent, cache, input_map)

    fun = fn params, inputs ->
      config = [{0, 0, 0}, {0, 0, 0} | Enum.map(config, fn {x, y} -> {x, y, 0} end)]
      apply(Nx, :pad, [fun.(params, inputs), value, config])
    end

    {fun, cache}
  end

  defp recur_predict_fun(
         %Axon{op: :concatenate, parent: parents, opts: [axis: axis]},
         cache,
         input_map
       ) do
    {funs, cache} = Enum.map_reduce(parents, cache, &to_predict_fun(&1, &2, input_map))

    fun = fn params, inputs ->
      inps = Enum.map(funs, & &1.(params, inputs))
      apply(Nx, :concatenate, [inps, [axis: axis]])
    end

    {fun, cache}
  end

  ## Special Layers

  defp recur_predict_fun(
         %Axon{op: :nx, parent: parent, opts: [fun: nx_fun]},
         cache,
         input_map
       ) do
    {fun, cache} = to_predict_fun(parent, cache, input_map)

    fun = fn params, inputs ->
      nx_fun.(fun.(params, inputs))
    end

    {fun, cache}
  end

  defp recur_predict_fun(%Axon{op: :input, id: id}, cache, input_map) do
    fun = fn _, inputs ->
      if is_tuple(inputs) do
        idx = input_map[id]
        elem(inputs, idx)
      else
        inputs
      end
    end

    {fun, cache}
  end

  defp maybe_freeze(param, true), do: Nx.Defn.Kernel.stop_grad(param)
  defp maybe_freeze(param, false), do: param

  ## Penalty Function Compilation

  @doc false
  def __jit_penalty__(graph, caller, args, opts) do
    fun = compile_penalty(graph)
    jit_or_apply(caller, fun, args, opts)
  end

  defp compile_penalty(graph) when is_tuple(graph) do
    graph = Tuple.to_list(graph)

    penalties =
      graph
      |> Enum.reduce(
        %{},
        fn x, cache ->
          to_penalty_fun(x, cache)
        end
      )

    [fun | funs] = Map.values(penalties)

    fn params ->
      funs
      |> Enum.reduce(fun.(params), fn penalty, acc -> Nx.add(penalty.(params), acc) end)
    end
  end

  defp compile_penalty(%Axon{} = graph) do
    penalties = to_penalty_fun(graph, %{})
    [fun | funs] = Map.values(penalties)

    fn params ->
      funs
      |> Enum.reduce(fun.(params), fn penalty, acc -> Nx.add(penalty.(params), acc) end)
    end
  end

  defp to_penalty_fun(%Axon{parent: parents}, cache) when is_list(parents) do
    Enum.reduce(parents, cache, fn graph, cache ->
      to_penalty_fun(graph, cache)
    end)
  end

  defp to_penalty_fun(%Axon{parent: parent, params: params}, cache) do
    cache =
      params
      |> Enum.reduce(cache, fn {_, param}, cache ->
        %{name: name, regularizer: regularizer} = param

        case cache do
          %{^name => _} ->
            cache

          %{} ->
            fun = fn params ->
              case regularizer do
                :none ->
                  Nx.tensor(0.0)

                regularizer when is_atom(regularizer) ->
                  apply(Axon.Regularizers, regularizer, [params[name]])

                regularizer when is_function(regularizer) ->
                  apply(regularizer, [params[name]])
              end
            end

            Map.put(cache, name, fun)
        end
      end)

    if parent do
      to_penalty_fun(parent, cache)
    else
      cache
    end
  end
end
