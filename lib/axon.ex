defmodule Axon do
  @moduledoc """
  A high-level interface for creating neural network models.

  Axon is built entirely on top of Nx numerical definitions,
  so every neural network can be JIT or AOT compiled using
  any Nx compiler, or even transformed into high-level neural
  network formats like TensorFlow Lite and ONNX.

  All Axon models start with an input layer, specifying the
  expected input shape of the training data:

      input = Axon.input({nil, 784})

  Notice you can specify the batch dimension as `nil`. You can
  then compose inputs with other layers:

      model =
        input
        |> Axon.dense(128, activation: :relu)
        |> Axon.batch_norm()
        |> Axon.dropout(rate: 0.8)
        |> Axon.dense(64)
        |> Axon.tanh()
        |> Axon.dense(10)
        |> Axon.activation(:softmax)

  You can inspect the model for a nice summary:

      IO.inspect(model)

      -----------------------------------------------------
                        Model
      =====================================================
       Layer                       Shape        Parameters
      =====================================================
       input_1 (input)             {nil, 784}   0
       dense_2 (dense)             {nil, 128}   100480
       relu_3 (relu)               {nil, 128}   0
       batch_norm_4 (batch_norm)   {nil, 128}   256
       dropout_5 (dropout)         {nil, 128}   0
       dense_6 (dense)             {nil, 64}    8256
       tanh_7 (tanh)               {nil, 64}    0
       dense_8 (dense)             {nil, 10}    650
       softmax_9 (softmax)         {nil, 10}    0
      -----------------------------------------------------

  Under the hood, Axon models are represented as Elixir structs. You
  can initialize and apply models using the macros `Axon.init/2` and
  `Axon.predict/4`:

      params = Axon.init(model, compiler: EXLA)

      Axon.predict(model, params, inputs, compiler: EXLA)

  Both `Axon.init/2` and `Axon.predict/4` can be used from within
  Nx defn or outside.

  Combining the Axon model creation API with the optimization and training
  APIs, you can create and train neural networks with ease:

      model =
        Axon.input({nil, 784})
        |> Axon.dense(128, activation: :relu)
        |> Axon.layer_norm()
        |> Axon.dropout()
        |> Axon.dense(10, activation: :softmax)

      IO.inspect model

      final_params =
        model
        |> Axon.Training.step(:categorical_cross_entropy, Axon.Optimizers.adamw(0.005))
        |> Axon.Training.train(train_images, train_labels, epochs: 10, compiler: EXLA)
  """
  alias __MODULE__, as: Axon

  @type t :: %__MODULE__{}

  @doc false
  defstruct [:id, :name, :output_shape, :parent, :op, :params, :opts]

  @doc """
  Custom Axon layer with given parent.

  Applies `op` on `parent` with parameters `parameters`. `parameters`
  is a map of trainable `parameters` created using `Axon.param`. Assumes
  `op` is a function of the following form:

      op = fn input, params -> ... end

  If `opts` is not empty, it is treated as input options to the layer
  method:

      op = fn input, params, opts -> ... end

  Parameters are accessed using the same key referenced in the `parameters`
  map passed to `Axon.layer`:

      w1 = Axon.param("weight", {})
      b1 = Axon.param("bias", {})

      op = fn input, params -> params["weight"] * input + params["bias"] end

      Axon.layer(parent, op, {}, %{"weight" => w1, "bias" => b1})
  """
  @doc type: :special
  def layer(parent, op, output_shape, parameters, name \\ nil, opts \\ [])
      when is_atom(op) or (is_function(op) and is_map(parameters)) do
    op_name = if is_atom(op), do: op, else: :layer

    {id, name} = unique_identifiers(op_name, name)

    parameters =
      parameters
      |> Enum.map(fn {k, %{name: p_name} = param} ->
        {k, %{param | name: name <> "_" <> p_name}}
      end)
      |> Map.new()

    %Axon{
      id: id,
      name: name,
      output_shape: output_shape,
      parent: parent,
      op: op,
      params: parameters,
      opts: opts
    }
  end

  @doc """
  Trainable Axon parameter used to create custom layers.

  Parameters are specified in usages of `Axon.layer` and will
  be automatically initialized and used in subsequent applications
  of Axon models.

  Parameters *must* be specified in order of their usage.

  ## Options

    * `initializer` - parameter initializer. Defaults to `:glorot_uniform`.
    * `:regularizer` - parameter regularizer. Defaults to `:none`.

  """
  def param(name, shape, opts \\ []) do
    initializer = opts[:initializer] || :glorot_uniform
    validate_initializer!(initializer)
    regularizer = opts[:regularizer] || :none
    validate_regularizer!(regularizer)

    id = System.unique_integer([:positive, :monotonic])

    %Axon.Parameter{
      id: id,
      name: name,
      shape: shape,
      initializer: initializer,
      regularizer: regularizer
    }
  end

  @doc """
  Adds an input layer to the network.

  Input layers specify a model's inputs. Input layers are
  always the root layers of the neural network.

  ## Options

    * `name` - Layer name.

  """
  @doc type: :special
  def input(input_shape, opts \\ []) do
    output_shape = Axon.Shape.input(input_shape)
    layer(nil, :input, output_shape, %{}, opts[:name], opts)
  end

  @doc """
  Adds a dense layer to the network.

  The dense layer implements:

      output = activation(dot(input, kernel) + bias)

  where `activation` is given by the `:activation` option and both
  `kernel` and `bias` are layer parameters. `units` specifies the
  number of output units.

  Compiles to `Axon.Layers.dense/3`.

  ## Options

    * `name` - Layer name.
    * `kernel_initializer` - Initializer for `kernel` weights.
    * `bias_initializer` - Initializer for `bias` weights.
    * `activation` - Element-wise activation function.

  """
  @doc type: :linear
  def dense(%Axon{output_shape: parent_shape} = x, units, opts \\ [])
      when is_integer(units) and units > 0 do
    activation = opts[:activation]

    kernel_shape = Axon.Shape.dense_kernel(parent_shape, units)
    bias_shape = Axon.Shape.dense_bias(parent_shape, units)
    output_shape = Axon.Shape.dense(parent_shape, units)

    kernel_initializer = opts[:kernel_initializer]
    kernel_regularizer = opts[:kernel_regularizer]

    kernel =
      param("kernel", kernel_shape,
        initializer: kernel_initializer,
        regularizer: kernel_regularizer
      )

    bias_initializer = opts[:bias_initializer] || :zeros
    bias_regularizer = opts[:bias_regularizer]
    bias = param("bias", bias_shape, initializer: bias_initializer, regularizer: bias_regularizer)

    node = layer(x, :dense, output_shape, %{"kernel" => kernel, "bias" => bias}, opts[:name])

    if activation do
      node
      |> activation(activation)
    else
      node
    end
  end

  @doc """
  Adds a convolution layer to the network.

  The convolution layer implements a general dimensional
  convolutional layer - which convolves a kernel over the input
  to produce an output.

  Compiles to `Axon.Layers.conv/4`.

  ## Options

    * `name` - Layer name.
    * `kernel_initializer` - Initializer for `kernel` weights.
    * `bias_initializer` - Initializer for `bias` weights.
    * `activation` - Element-wise activation function.
    * `kernel_size` - Size of the kernel spatial dimensions.
    * `strides` - Stride during convolution.
    * `padding` - Padding to the spatial dimensions of the input.
    * `input_dilation` - Dilation to apply to input.
    * `kernel_dilation` - Dilation to apply to kernel.

  """
  @doc type: :convolution
  def conv(%Axon{output_shape: parent_shape} = x, units, opts \\ [])
      when is_integer(units) and units > 0 do
    activation = opts[:activation]

    kernel_size = opts[:kernel_size] || 1
    strides = opts[:strides] || 1
    padding = opts[:padding] || :valid
    input_dilation = opts[:input_dilation] || 1
    kernel_dilation = opts[:kernel_dilation] || 1
    inner_rank = Nx.rank(parent_shape) - 2

    kernel_size = tuple_or_duplicate(:kernel_size, kernel_size, inner_rank)
    strides = list_or_duplicate(:strides, strides, inner_rank)
    input_dilation = list_or_duplicate(:input_dilation, input_dilation, inner_rank)
    kernel_dilation = list_or_duplicate(:kernel_dilation, kernel_dilation, inner_rank)

    kernel_shape = Axon.Shape.conv_kernel(parent_shape, units, kernel_size)
    bias_shape = Axon.Shape.conv_bias(parent_shape, units, kernel_size)

    output_shape =
      Axon.Shape.conv(
        parent_shape,
        kernel_shape,
        strides,
        padding,
        input_dilation,
        kernel_dilation
      )

    kernel_initializer = opts[:kernel_initializer]
    kernel_regularizer = opts[:kernel_regularizer]

    kernel =
      param("kernel", kernel_shape,
        initializer: kernel_initializer,
        regularizer: kernel_regularizer
      )

    bias_initializer = opts[:bias_initializer] || :zeros
    bias_regularizer = opts[:bias_regularizer]
    bias = param("bias", bias_shape, initializer: bias_initializer, regularizer: bias_regularizer)

    node =
      layer(x, :conv, output_shape, %{"kernel" => kernel, "bias" => bias}, opts[:name],
        strides: strides,
        padding: padding,
        input_dilation: input_dilation,
        kernel_dilation: kernel_dilation
      )

    if activation do
      node
      |> activation(activation)
    else
      node
    end
  end

  @doc """
  Adds a transposed convolution layer to the network.

  The tranposed convolution layer is sometimes referred to as a
  fractionally strided convolution or (incorrectly) as a deconvolution.

  Compiles to `Axon.Layers.conv_transpose/4`.

  ## Options

    * `name` - Layer name.
    * `kernel_initializer` - Initializer for `kernel` weights.
    * `bias_initializer` - Initializer for `bias` weights.
    * `activation` - Element-wise activation function.
    * `kernel_size` - Size of the kernel spatial dimensions.
    * `strides` - Stride during convolution.
    * `padding` - Padding to the spatial dimensions of the input.
    * `kernel_dilation` - Dilation to apply to kernel.
  """
  @doc type: :convolution
  def conv_transpose(%Axon{output_shape: parent_shape} = x, units, opts \\ []) do
    activation = opts[:activation]

    kernel_size = opts[:kernel_size] || 1
    strides = opts[:strides] || 1
    padding = opts[:padding] || :valid
    kernel_dilation = opts[:kernel_dilation] || 1
    inner_rank = Nx.rank(parent_shape) - 2

    kernel_size = tuple_or_duplicate(:kernel_size, kernel_size, inner_rank)
    strides = list_or_duplicate(:strides, strides, inner_rank)
    kernel_dilation = list_or_duplicate(:kernel_dilation, kernel_dilation, inner_rank)

    kernel_shape = Axon.Shape.conv_kernel(parent_shape, units, kernel_size)
    bias_shape = Axon.Shape.conv_bias(parent_shape, units, kernel_size)

    kernel_initializer = opts[:kernel_initializer]
    kernel_regularizer = opts[:kernel_regularizer]

    kernel =
      param("kernel", kernel_shape,
        initializer: kernel_initializer,
        regularizer: kernel_regularizer
      )

    bias_initializer = opts[:bias_initializer] || :zeros
    bias_regularizer = opts[:bias_regularizer]
    bias = param("bias", bias_shape, initializer: bias_initializer, regularizer: bias_regularizer)

    output_shape =
      Axon.Shape.conv_transpose(
        parent_shape,
        kernel_shape,
        strides,
        padding,
        kernel_dilation
      )

    node =
      layer(x, :conv_transpose, output_shape, %{"kernel" => kernel, "bias" => bias}, opts[:name],
        strides: strides,
        padding: padding,
        kernel_dilation: kernel_dilation
      )

    if activation do
      node
      |> activation(activation)
    else
      node
    end
  end

  @doc """
  Adds a depthwise convolution layer to the network.

  The depthwise convolution layer implements a general
  dimensional depthwise convolution - which is a convolution
  where the feature group size is equal to the number of
  input channels.

  Channel multiplier grows the input channels by the given
  factor. An input factor of 1 means the output channels
  are the same as the input channels.

  Compiles to `Axon.Layers.depthwise_conv`/4.

  ## Options

    * `name` - Layer name.
    * `kernel_initializer` - Initializer for `kernel` weights.
    * `bias_initializer` - Initializer for `bias` weights.
    * `activation` - Element-wise activation function.
    * `kernel_size` - Size of the kernel spatial dimensions.
    * `strides` - Stride during convolution.
    * `padding` - Padding to the spatial dimensions of the input.
    * `input_dilation` - Dilation to apply to input.
    * `kernel_dilation` - Dilation to apply to kernel.

  """
  @doc type: :convolution
  def depthwise_conv(%Axon{output_shape: parent_shape} = x, channel_multiplier, opts \\ [])
      when is_integer(channel_multiplier) and channel_multiplier >= 1 do
    activation = opts[:activation]

    kernel_size = opts[:kernel_size] || 1
    strides = opts[:strides] || 1
    padding = opts[:padding] || :valid
    input_dilation = opts[:input_dilation] || 1
    kernel_dilation = opts[:kernel_dilation] || 1
    inner_rank = Nx.rank(parent_shape) - 2

    kernel_size = tuple_or_duplicate(:kernel_size, kernel_size, inner_rank)
    strides = list_or_duplicate(:strides, strides, inner_rank)
    input_dilation = list_or_duplicate(:input_dilation, input_dilation, inner_rank)
    kernel_dilation = list_or_duplicate(:kernel_dilation, kernel_dilation, inner_rank)

    kernel_shape = Axon.Shape.depthwise_conv_kernel(parent_shape, channel_multiplier, kernel_size)
    bias_shape = Axon.Shape.depthwise_conv_bias(parent_shape, channel_multiplier, kernel_size)

    output_shape =
      Axon.Shape.depthwise_conv(
        parent_shape,
        kernel_shape,
        strides,
        padding,
        input_dilation,
        kernel_dilation
      )

    kernel_initializer = opts[:kernel_initializer]
    kernel_regularizer = opts[:kernel_regularizer]

    kernel =
      param("weight", kernel_shape,
        initializer: kernel_initializer,
        regularizer: kernel_regularizer
      )

    bias_initializer = opts[:bias_initializer] || :zeros
    bias_regularizer = opts[:bias_regularizer]
    bias = param("bias", bias_shape, initializer: bias_initializer, regularizer: bias_regularizer)

    node =
      layer(x, :depthwise_conv, output_shape, %{"kernel" => kernel, "bias" => bias}, opts[:name],
        strides: strides,
        padding: padding,
        input_dilation: input_dilation,
        kernel_dilation: kernel_dilation
      )

    if activation do
      node
      |> activation(activation)
    else
      node
    end
  end

  @doc """
  Adds a depthwise separable 2-dimensional convolution to the
  network.

  Depthwise separable convolutions break the kernel into kernels
  for each dimension of the input and perform a depthwise conv
  over the input with each kernel.

  Compiles to `Axon.Layers.separable_conv2d/6`.

  ## Options

    * `name` - Layer name.
    * `kernel_initializer` - Initializer for `kernel` weights.
    * `bias_initializer` - Initializer for `bias` weights.
    * `activation` - Element-wise activation function.
    * `kernel_size` - Size of the kernel spatial dimensions.
    * `strides` - Stride during convolution.
    * `padding` - Padding to the spatial dimensions of the input.
    * `input_dilation` - Dilation to apply to input.
    * `kernel_dilation` - Dilation to apply to kernel.

  """
  @doc type: :convolution
  def separable_conv2d(%Axon{output_shape: parent_shape} = x, channel_multiplier, opts \\ [])
      when is_integer(channel_multiplier) and channel_multiplier >= 1 do
    activation = opts[:activation]

    kernel_size = opts[:kernel_size] || 1
    strides = opts[:strides] || 1
    padding = opts[:padding] || :valid
    input_dilation = opts[:input_dilation] || 1
    kernel_dilation = opts[:kernel_dilation] || 1
    inner_rank = Nx.rank(parent_shape) - 2

    kernel_size = tuple_or_duplicate(:kernel_size, kernel_size, inner_rank)
    strides = list_or_duplicate(:strides, strides, inner_rank)
    input_dilation = list_or_duplicate(:input_dilation, input_dilation, inner_rank)
    kernel_dilation = list_or_duplicate(:kernel_dilation, kernel_dilation, inner_rank)

    k1_shape =
      Axon.Shape.separable_conv2d_kernel(parent_shape, channel_multiplier, kernel_size, 1)

    k2_shape =
      Axon.Shape.separable_conv2d_kernel(parent_shape, channel_multiplier, kernel_size, 2)

    b1_shape = Axon.Shape.separable_conv2d_bias(parent_shape, channel_multiplier, kernel_size)
    b2_shape = Axon.Shape.separable_conv2d_bias(parent_shape, channel_multiplier, kernel_size)

    output_shape =
      Axon.Shape.depthwise_conv(
        parent_shape,
        Axon.Shape.depthwise_conv_kernel(parent_shape, channel_multiplier, kernel_size),
        strides,
        padding,
        input_dilation,
        kernel_dilation
      )

    kernel_initializer = opts[:kernel_initializer]
    kernel_regularizer = opts[:kernel_regularizer]

    k1 =
      param("kernel_1", k1_shape, initializer: kernel_initializer, regularizer: kernel_regularizer)

    k2 =
      param("kernel_2", k2_shape, initializer: kernel_initializer, regularizer: kernel_regularizer)

    bias_initializer = opts[:bias_initializer] || :zeros
    bias_regularizer = opts[:bias_regularizer]
    b1 = param("bias_1", b1_shape, initializer: bias_initializer, regularizer: bias_regularizer)
    b2 = param("bias_2", b2_shape, initializer: bias_initializer, regularizer: bias_regularizer)

    node =
      layer(
        x,
        :separable_conv2d,
        output_shape,
        %{"k1" => k1, "b1" => b1, "k2" => k2, "b2" => b2},
        opts[:name],
        strides: strides,
        padding: padding,
        input_dilation: input_dilation,
        kernel_dilation: kernel_dilation
      )

    if activation do
      node
      |> activation(activation)
    else
      node
    end
  end

  @doc """
  Adds a depthwise separable 3-dimensional convolution to the
  network.

  Depthwise separable convolutions break the kernel into kernels
  for each dimension of the input and perform a depthwise conv
  over the input with each kernel.

  Compiles to `Axon.Layers.separable_conv3d/8`.

  ## Options

    * `name` - Layer name.
    * `kernel_initializer` - Initializer for `kernel` weights.
    * `bias_initializer` - Initializer for `bias` weights.
    * `activation` - Element-wise activation function.
    * `kernel_size` - Size of the kernel spatial dimensions.
    * `strides` - Stride during convolution.
    * `padding` - Padding to the spatial dimensions of the input.
    * `input_dilation` - Dilation to apply to input.
    * `kernel_dilation` - Dilation to apply to kernel.

  """
  @doc type: :convolution
  def separable_conv3d(%Axon{output_shape: parent_shape} = x, channel_multiplier, opts \\ [])
      when is_integer(channel_multiplier) and channel_multiplier >= 1 do
    activation = opts[:activation]

    kernel_size = opts[:kernel_size] || 1
    strides = opts[:strides] || 1
    padding = opts[:padding] || :valid
    input_dilation = opts[:input_dilation] || 1
    kernel_dilation = opts[:kernel_dilation] || 1
    inner_rank = Nx.rank(parent_shape) - 2

    kernel_size = tuple_or_duplicate(:kernel_size, kernel_size, inner_rank)
    strides = list_or_duplicate(:strides, strides, inner_rank)
    input_dilation = list_or_duplicate(:input_dilation, input_dilation, inner_rank)
    kernel_dilation = list_or_duplicate(:kernel_dilation, kernel_dilation, inner_rank)

    k1_shape =
      Axon.Shape.separable_conv3d_kernel(parent_shape, channel_multiplier, kernel_size, 1)

    k2_shape =
      Axon.Shape.separable_conv3d_kernel(parent_shape, channel_multiplier, kernel_size, 2)

    k3_shape =
      Axon.Shape.separable_conv3d_kernel(parent_shape, channel_multiplier, kernel_size, 3)

    b1_shape = Axon.Shape.separable_conv3d_bias(parent_shape, channel_multiplier, kernel_size)
    b2_shape = Axon.Shape.separable_conv3d_bias(parent_shape, channel_multiplier, kernel_size)
    b3_shape = Axon.Shape.separable_conv3d_bias(parent_shape, channel_multiplier, kernel_size)

    output_shape =
      Axon.Shape.depthwise_conv(
        parent_shape,
        Axon.Shape.depthwise_conv_kernel(parent_shape, channel_multiplier, kernel_size),
        strides,
        padding,
        input_dilation,
        kernel_dilation
      )

    kernel_initializer = opts[:kernel_initializer]
    kernel_regularizer = opts[:kernel_regularizer]

    k1 =
      param("kernel_1", k1_shape, initializer: kernel_initializer, regularizer: kernel_regularizer)

    k2 =
      param("kernel_2", k2_shape, initializer: kernel_initializer, regularizer: kernel_regularizer)

    k3 =
      param("kernel_3", k3_shape, initializer: kernel_initializer, regularizer: kernel_regularizer)

    bias_initializer = opts[:bias_initializer] || :zeros
    bias_regularizer = opts[:bias_regularizer]
    b1 = param("bias_1", b1_shape, initializer: bias_initializer, regularizer: bias_regularizer)
    b2 = param("bias_2", b2_shape, initializer: bias_initializer, regularizer: bias_regularizer)
    b3 = param("bias_3", b3_shape, initializer: bias_initializer, regularizer: bias_regularizer)

    node =
      layer(
        x,
        :separable_conv3d,
        output_shape,
        %{"k1" => k1, "b1" => b1, "k2" => k2, "b2" => b2, "k3" => k3, "b3" => b3},
        opts[:name],
        strides: strides,
        padding: padding,
        input_dilation: input_dilation,
        kernel_dilation: kernel_dilation
      )

    if activation do
      node
      |> activation(activation)
    else
      node
    end
  end

  @activation_layers [
    {:celu, "Continuously-differentiable exponential linear unit", "a"},
    {:elu, "Exponential linear unit", "an"},
    {:exp, "Exponential", "an"},
    {:gelu, "Gaussian error linear unit", "a"},
    {:hard_sigmoid, "Hard sigmoid", "a"},
    {:hard_silu, "Hard sigmoid weighted linear unit", "a"},
    {:hard_tanh, "Hard hyperbolic tangent", "a"},
    {:leaky_relu, "Leaky rectified linear unit", "a"},
    {:linear, "Linear", "a"},
    {:log_sigmoid, "Log-sigmoid", "a"},
    {:mish, "Mish", "a"},
    {:relu, "Rectified linear unit", "a"},
    {:relu6, "Rectified linear unit 6", "a"},
    {:sigmoid, "Sigmoid", "a"},
    {:silu, "Sigmoid weighted linear unit", "a"},
    {:selu, "Scaled exponential linear unit", "a"},
    {:softmax, "Softmax", "a"},
    {:softplus, "Softplus", "a"},
    {:softsign, "Softsign", "a"},
    {:tanh, "Hyperbolic tangent", "a"}
  ]

  @doc """
  Adds an activation layer to the network.

  Activation layers are element-wise functions typically called
  after the output of another layer.

  ## Options

    - `name` - Layer name.

  """
  @doc type: :activation
  def activation(x, activation, opts \\ [])

  def activation(%Axon{output_shape: shape} = x, activation, opts) when is_atom(activation) do
    layer(x, activation, shape, %{}, opts[:name], opts)
  end

  def activation(%Axon{output_shape: shape} = x, activation, opts)
      when is_function(activation, 1) do
    layer(x, activation, shape, %{}, opts[:name], opts)
  end

  ## Activation

  for {activation, name, a_or_an} <- @activation_layers do
    @doc """
    Adds #{a_or_an} #{name} activation layer to the network.

    See `Axon.Activations.#{Atom.to_string(activation)}/1` for more details.

    ## Options

      - `name` - Layer name.

    """
    @doc type: :activation
    def unquote(activation)(%Axon{} = x, opts \\ []) do
      activation(x, unquote(activation), opts)
    end
  end

  ## Dropout

  @dropout_layers [
    {:dropout, "Dropout", "a"},
    {:feature_alpha_dropout, "Feature alpha dropout", "a"},
    {:spatial_dropout, "Spatial dropout", "a"},
    {:alpha_dropout, "Alpha dropout", "an"}
  ]

  for {dropout, name, a_or_an} <- @dropout_layers do
    @doc """
    Adds #{a_or_an} #{name} layer to the network.

    See `Axon.Layers.#{Atom.to_string(dropout)}/2` for more details.

    ## Options

      * `:name` - Layer name.
      * `:rate` - Dropout rate.

    """
    @doc type: :dropout
    def unquote(dropout)(%Axon{} = x, opts \\ []) do
      dropout(x, unquote(dropout), opts)
    end
  end

  defp dropout(%Axon{output_shape: parent_shape} = x, dropout, opts) do
    rate = opts[:rate] || 0.5
    layer(x, dropout, parent_shape, %{}, opts[:name], rate: rate)
  end

  ## Pooling

  @pooling_layers [
    {:max_pool, "Max pooling", "a"},
    {:avg_pool, "Average pooling", "an"},
    {:lp_pool, "Power average pooling", "a"}
  ]

  for {pool, name, a_or_an} <- @pooling_layers do
    @doc """
    Adds #{a_or_an} #{name} layer to the network.

    See `Axon.Layers.#{Atom.to_string(pool)}/2` for more details.

    ## Options

      * `:name` - Layer name.
      * `:kernel_size` - Pooling kernel size.
      * `:strides` - Pooling strides.

    """
    @doc type: :pooling
    def unquote(pool)(%Axon{} = x, opts \\ []) do
      pool(x, unquote(pool), opts)
    end
  end

  defp pool(%Axon{output_shape: parent_shape} = x, pool, opts) do
    kernel_size = opts[:kernel_size] || 1
    strides = opts[:strides] || 1
    padding = opts[:padding] || :valid
    inner_rank = Nx.rank(parent_shape) - 2

    kernel_size = tuple_or_duplicate(:kernel_size, kernel_size, inner_rank)
    strides = list_or_duplicate(:strides, strides, inner_rank)
    output_shape = Axon.Shape.pool(parent_shape, kernel_size, strides, padding)

    layer(x, pool, output_shape, %{}, opts[:name],
      kernel_size: kernel_size,
      strides: strides,
      padding: padding
    )
  end

  ## Adaptive Pooling

  @adaptive_pooling_layers [
    {:adaptive_avg_pool, "Adaptive average pooling", "an"},
    {:adaptive_max_pool, "Adaptive max pooling", "an"}
  ]

  for {pool, name, a_or_an} <- @adaptive_pooling_layers do
    @doc """
    Adds #{a_or_an} #{name} layer to the network.

    See `Axon.Layers.#{Atom.to_string(pool)}/2` for more details.

    ## Options

      * `:name` - Layer name.
      * `:output_size` - Layer output size.

    """
    @doc type: :pooling
    def unquote(pool)(%Axon{} = x, opts \\ []) do
      adaptative_pool(x, unquote(pool), opts)
    end
  end

  defp adaptative_pool(%Axon{output_shape: parent_shape} = x, pool, opts) do
    inner_rank = Nx.rank(parent_shape) - 2

    output_size = tuple_or_duplicate(:output_size, opts[:output_size], inner_rank)
    output_shape = Axon.Shape.adaptive_pool(parent_shape, output_size)

    layer(x, pool, output_shape, %{}, opts[:name], output_size: output_size)
  end

  ## Normalization

  @normalization_layers [
    {:batch_norm, "Batch normalization", "a"},
    {:layer_norm, "Layer normalization", "a"},
    {:instance_norm, "Instance normalization", "an"}
  ]

  for {norm, name, a_or_an} <- @normalization_layers do
    @doc """
    Adds #{a_or_an} #{name} layer to the network.

    See `Axon.Layers.#{Atom.to_string(norm)}/4` for more details.

    ## Options

      * `:name` - Layer name.
      * `:gamma_initializer` - Gamma parameter initializer.
      * `:beta_initializer` - Beta parameter initializer.
      * `:channel_index` - Input feature index used for calculating
        mean and variance.
      * `:epsilon` - Numerical stability term.

    """
    @doc type: :normalization
    def unquote(norm)(%Axon{} = x, opts \\ []) do
      norm(x, unquote(norm), opts)
    end
  end

  defp norm(%Axon{output_shape: shape} = x, norm, opts) do
    channel_index = opts[:channel_index] || 1
    epsilon = opts[:epsilon] || 1.0e-5

    gamma_shape = Axon.Shape.norm_param(shape, channel_index)
    beta_shape = Axon.Shape.norm_param(shape, channel_index)

    gamma_initializer = opts[:gamma_initializer]
    gamma_regularizer = opts[:gamma_regularizer]

    gamma =
      param("gamma", gamma_shape, initializer: gamma_initializer, regularizer: gamma_regularizer)

    beta_initializer = opts[:beta_initializer] || :zeros
    beta_regularizer = opts[:beta_regularizer]
    beta = param("beta", beta_shape, initializer: beta_initializer, regularizer: beta_regularizer)

    layer(x, norm, shape, %{"gamma" => gamma, "beta" => beta}, opts[:name],
      epsilon: epsilon,
      channel_index: channel_index
    )
  end

  @doc """
  Adds a group normalization layer to the network.

  See `Axon.Layers.group_norm/4` for more details.

  ## Options

    * `:name` - Layer name.
    * `:gamma_initializer` - Gamma parameter initializer.
    * `:beta_initializer` - Beta parameter initializer.
    * `:channel_index` - Input feature index used for calculating
      mean and variance.
    * `:epsilon` - Numerical stability term.

  """
  @doc type: :normalization
  def group_norm(%Axon{output_shape: shape} = x, group_size, opts \\ [])
      when is_integer(group_size) and group_size >= 1 do
    channel_index = opts[:channel_index] || 1
    epsilon = opts[:epsilon] || 1.0e-5

    gamma_shape = Axon.Shape.norm_param(shape, channel_index)
    beta_shape = Axon.Shape.norm_param(shape, channel_index)

    gamma_initializer = opts[:gamma_initializer]
    gamma_regularizer = opts[:gamma_regularizer]

    gamma =
      param("gamma", gamma_shape, initializer: gamma_initializer, regularizer: gamma_regularizer)

    beta_initializer = opts[:beta_initializer] || :zeros
    beta_regularizer = opts[:beta_regularizer]
    beta = param("beta", beta_shape, initializer: beta_initializer, regularizer: beta_regularizer)

    layer(x, :group_norm, shape, %{"gamma" => gamma, "beta" => beta}, opts[:name],
      epsilon: epsilon,
      channel_index: channel_index,
      group_size: group_size
    )
  end

  @doc """
  Applies the given `Nx` expression to the input.

  ## Options

    * `name` - Layer name.

  """
  @doc type: :special
  def nx(%Axon{output_shape: shape} = x, fun, opts \\ []) when is_function(fun, 1) do
    # Some shape rules will not like nil batch shape
    batch_size = elem(shape, 0)
    shape = Tuple.delete_at(shape, 0)

    param = Nx.Defn.Expr.parameter(:nx, {:f, 32}, shape, 0)

    expr = Nx.Defn.jit(fun, [param], compiler: Axon.Defn)
    output_shape = Tuple.insert_at(expr.shape, 0, batch_size)

    layer(x, fun, output_shape, %{}, opts[:name])
  end

  @doc """
  Adds a flatten layer to the network.

  This layer will flatten all but the batch dimensions
  of the input into a single layer. Typically called to flatten
  the output of a convolution for use with a dense layer.

  ## Options

    * `:name` - Layer name.

  """
  @doc type: :shape
  def flatten(%Axon{output_shape: shape} = x, opts \\ []) do
    output_shape = Axon.Shape.flatten(shape)
    layer(x, :flatten, output_shape, %{}, opts[:name])
  end

  @doc """
  Adds a reshape layer to the network.

  This layer will reshape non-batch dimensions of the input.
  New shape must be compatible with old shape.

  ## Options

    * `:name` - Layer name.
  """
  @doc type: :shape
  def reshape(%Axon{output_shape: shape} = x, new_shape, opts \\ []) do
    output_shape = Axon.Shape.reshape(shape, new_shape)
    layer(x, :reshape, output_shape, %{}, opts[:name])
  end

  @doc """
  Adds a transpose layer to the network.

  This layer will transpose non-batch dimensions of the input.

  ## Options

    * `:name` - Layer name.
  """
  @doc type: :shape
  def transpose(%Axon{output_shape: shape} = x, permutation, opts \\ []) do
    output_shape = Axon.Shape.transpose(shape, permutation)
    layer(x, :transpose, output_shape, %{}, opts[:name], permutation: permutation)
  end

  @doc """
  Adds a pad layer to the network.

  This layer will pad the spatial dimensions of the input.
  Padding configuration is a list of tuples for each spatial
  dimension.

  ## Options

    * `:name` - Layer name.
  """
  @doc type: :shape
  def pad(%Axon{output_shape: shape} = x, config, value \\ 0.0, opts \\ [])
      when is_list(config) and is_number(value) do
    output_shape = Axon.Shape.pad(shape, config)
    layer(x, :pad, output_shape, %{}, opts[:name], padding_config: config, value: value)
  end

  @doc """
  Adds a concatenate layer to the network.

  This layer will concatenate inputs along the last
  dimension unless specified otherwise.

  ## Options

    * `:name` - Layer name.
    * `:axis` - Concatenate axis.

  """
  @doc type: :composition
  def concatenate(%Axon{output_shape: x_shape} = x, %Axon{output_shape: y_shape} = y, opts)
      when is_list(opts) do
    axis = opts[:axis] || Nx.rank(x_shape) - 1
    output_shape = Axon.Shape.concatenate([x_shape, y_shape], axis)

    layer([x, y], :concatenate, output_shape, %{}, opts[:name], axis: axis)
  end

  @doc type: :composition
  def concatenate([%Axon{output_shape: shape} | _] = inputs, opts)
      when is_list(inputs) and is_list(opts) do
    axis = opts[:axis] || Nx.rank(shape) - 1
    input_shapes = inputs |> Enum.map(fn %Axon{output_shape: shape} -> shape end)
    output_shape = Axon.Shape.concatenate(input_shapes, axis)

    layer(inputs, :concatenate, output_shape, %{}, opts[:name], axis: axis)
  end

  @doc false
  def concatenate(%Axon{} = x, %Axon{} = y), do: concatenate(x, y, [])

  @doc false
  def concatenate(inputs) when is_list(inputs), do: concatenate(inputs, [])

  @element_wise_layers [:add, :subtract, :multiply]

  for op <- @element_wise_layers do
    @doc """
    Adds a #{op} layer to the network.

    This layer performs an element-wise #{Atom.to_string(op)} operation
    on input layers. All input layers must be the same shape.

    ## Options

      * `:name` - Layer name.

    """
    @doc type: :composition
    def unquote(op)(%Axon{output_shape: shape} = x, %Axon{output_shape: shape} = y, opts) do
      Axon.layer([x, y], unquote(op), shape, %{}, opts[:name])
    end

    @doc """
    Adds a #{op} layer to the network.

    This layer performs an element-wise #{Atom.to_string(op)} operation
    on all input layers. All input layers must be the same shape.

    ## Options

      * `:name` - Layer name.

    """
    @doc type: :composition
    def unquote(op)([%Axon{output_shape: shape} | rest] = inputs, opts)
        when is_list(inputs) and is_list(opts) do
      output_shape =
        Enum.reduce(rest, shape, fn %Axon{output_shape: shape}, acc ->
          unless shape == acc do
            raise ArgumentError, "all input shapes must match"
          end

          shape
        end)

      layer(inputs, unquote(op), output_shape, %{}, [], opts[:name])
    end

    @doc false
    def unquote(op)(%Axon{output_shape: shape} = x, %Axon{output_shape: shape} = y) do
      unquote(op)(x, y, [])
    end

    @doc false
    def unquote(op)([%Axon{} | _] = inputs), do: unquote(op)(inputs, [])
  end

  @doc """
  Adds a long short-term memory (LSTM) layer to the network.

  LSTMs apply `Axon.Recurrent.lstm_cell/7` over an entire input
  sequence and return:

      {{new_cell, new_hidden}, output_sequence}

  You can use the output state as the hidden state of another
  LSTM layer with the `:hidden_state` option.

  ## Options

    * `:activation` - recurrent activation. Defaults to `:tanh`.
    * `:gate` - recurrent gate function. Defaults to `:sigmoid`.
    * `:hidden_state` - initial hidden state. Defaults to `nil`.
    * `:unroll` - `:dynamic` (loop preserving) or `:static` (compiled)
      unrolling of RNN.

  """
  @doc type: :recurrent
  def lstm(%Axon{output_shape: shape} = x, units, opts \\ [])
      when is_integer(units) and units > 0 do
    activation = opts[:activation] || :tanh
    gate = opts[:gate] || :sigmoid
    hidden_state = opts[:hidden_state]
    unroll = opts[:unroll] || :dynamic

    output_shape = Axon.Shape.rnn(shape, units, "LSTM")
    input_kernel_shape = Axon.Shape.rnn_input_kernel(shape, units, "LSTM")
    hidden_kernel_shape = Axon.Shape.rnn_hidden_kernel(shape, units, "LSTM")
    bias_shape = Axon.Shape.rnn_bias(shape, units, "LSTM")
    hidden_state_shape = Axon.Shape.rnn_hidden_state(shape, units, "LSTM")

    kernel_initializer = opts[:kernel_initializer] || :glorot_uniform
    recurrent_initializer = opts[:recurrent_initializer] || :glorot_uniform
    bias_initializer = opts[:bias_initializer] || :zeros

    # Parameters
    wii = param("wii", input_kernel_shape, initializer: kernel_initializer)
    wif = param("wif", input_kernel_shape, initializer: kernel_initializer)
    wig = param("wig", input_kernel_shape, initializer: kernel_initializer)
    wio = param("wio", input_kernel_shape, initializer: kernel_initializer)

    whi = param("whi", hidden_kernel_shape, initializer: kernel_initializer)
    whf = param("whf", hidden_kernel_shape, initializer: kernel_initializer)
    whg = param("whg", hidden_kernel_shape, initializer: kernel_initializer)
    who = param("who", hidden_kernel_shape, initializer: kernel_initializer)

    bi = param("bi", bias_shape, initializer: bias_initializer)
    bf = param("bf", bias_shape, initializer: bias_initializer)
    bg = param("bg", bias_shape, initializer: bias_initializer)
    bo = param("bo", bias_shape, initializer: bias_initializer)

    output =
      layer(
        x,
        :lstm,
        {{hidden_state_shape, hidden_state_shape}, output_shape},
        %{
          "wii" => wii,
          "wif" => wif,
          "wig" => wig,
          "wio" => wio,
          "whi" => whi,
          "whf" => whf,
          "whg" => whg,
          "who" => who,
          "bi" => bi,
          "bf" => bf,
          "bg" => bg,
          "bo" => bo
        },
        opts[:name],
        activation: activation,
        gate: gate,
        hidden_state: hidden_state,
        hidden_state_shape: hidden_state_shape,
        recurrent_initializer: recurrent_initializer,
        unroll: unroll
      )

    new_c = layer(output, fn x, _ -> elem(elem(x, 0), 0) end, hidden_state_shape, %{})
    new_h = layer(output, fn x, _ -> elem(elem(x, 0), 1) end, hidden_state_shape, %{})
    output_sequence = layer(output, fn x, _ -> elem(x, 1) end, output_shape, %{})

    {{new_c, new_h}, output_sequence}
  end

  @doc """
  Adds a gated recurrent unit (GRU) layer to the network.

  GRUs apply `Axon.Recurrent.gru_cell/7` over an entire input
  sequence and return:

      {{new_hidden}, output_sequence}

  You can use the output state as the hidden state of another
  LSTM layer with the `:hidden_state` option.

  ## Options

    * `:activation` - recurrent activation. Defaults to `:tanh`.
    * `:gate` - recurrent gate function. Defaults to `:sigmoid`.
    * `:hidden_state` - initial hidden state. Defaults to `nil`.
    * `:unroll` - `:dynamic` (loop preserving) or `:static` (compiled)
      unrolling of RNN.

  """
  @doc type: :recurrent
  def gru(%Axon{output_shape: shape} = x, units, opts \\ [])
      when is_integer(units) and units > 0 do
    activation = opts[:activation] || :tanh
    gate = opts[:gate] || :sigmoid
    hidden_state = opts[:hidden_state]
    unroll = opts[:unroll] || :dynamic

    output_shape = Axon.Shape.rnn(shape, units, "GRU")
    input_kernel_shape = Axon.Shape.rnn_input_kernel(shape, units, "GRU")
    hidden_kernel_shape = Axon.Shape.rnn_hidden_kernel(shape, units, "GRU")
    bias_shape = Axon.Shape.rnn_bias(shape, units, "GRU")
    hidden_state_shape = Axon.Shape.rnn_hidden_state(shape, units, "GRU")

    kernel_initializer = opts[:kernel_initializer] || :glorot_uniform
    recurrent_initializer = opts[:recurrent_initializer] || :glorot_uniform
    bias_initializer = opts[:bias_initializer] || :zeros

    wir = param("wir", input_kernel_shape, initializer: kernel_initializer)
    wiz = param("wiz", input_kernel_shape, initializer: kernel_initializer)
    win = param("win", input_kernel_shape, initializer: kernel_initializer)
    whr = param("whr", hidden_kernel_shape, initializer: kernel_initializer)
    whz = param("whz", hidden_kernel_shape, initializer: kernel_initializer)
    whn = param("whn", hidden_kernel_shape, initializer: kernel_initializer)
    br = param("br", bias_shape, initializer: bias_initializer)
    bz = param("bz", bias_shape, initializer: bias_initializer)
    bin = param("bin", bias_shape, initializer: bias_initializer)
    bhn = param("bhn", bias_shape, initializer: bias_initializer)

    output =
      layer(
        x,
        :gru,
        {{hidden_state_shape}, output_shape},
        %{
          "wir" => wir,
          "wiz" => wiz,
          "win" => win,
          "whr" => whr,
          "whz" => whz,
          "whn" => whn,
          "br" => br,
          "bz" => bz,
          "bin" => bin,
          "bhn" => bhn
        },
        opts[:name],
        activation: activation,
        gate: gate,
        hidden_state: hidden_state,
        hidden_state_shape: hidden_state_shape,
        recurrent_initializer: recurrent_initializer,
        unroll: unroll
      )

    new_h = layer(output, fn x, _ -> elem(elem(x, 0), 0) end, hidden_state_shape, %{})
    output_sequence = layer(output, fn x, _ -> elem(x, 1) end, output_shape, %{})

    {{new_h}, output_sequence}
  end

  @doc """
  Adds a convolutional long short-term memory (LSTM) layer to the network.

  ConvLSTMs apply `Axon.Recurrent.conv_lstm_cell/5` over an entire input
  sequence and return:

      {{new_cell, new_hidden}, output_sequence}

  You can use the output state as the hidden state of another
  LSTM layer with the `:hidden_state` option.

  ## Options

    * `:padding` - convolutional padding. Defaults to `:same`.
    * `:kernel_size` - convolutional kernel size. Defaults to `1`.
    * `:strides` - convolutional strides. Defaults to `1`.
    * `:hidden_state` - initial hidden state. Defaults to `nil`.
    * `:unroll` - `:dynamic` (loop preserving) or `:static` (compiled)
      unrolling of RNN.

  """
  @doc type: :recurrent
  def conv_lstm(%Axon{output_shape: shape} = x, units, opts \\ []) do
    padding = opts[:padding] || :same
    kernel_size = opts[:kernel_size] || 1
    strides = opts[:strides] || 1
    hidden_state = opts[:hidden_state]
    unroll = opts[:unroll] || :dynamic

    kernel_size = tuple_or_duplicate(:kernel_size, kernel_size, 1)
    strides = list_or_duplicate(:strides, strides, 1)

    hidden_state_shape = Axon.Shape.rnn_hidden_state(shape, units, "ConvLSTM")
    input_kernel_shape = Axon.Shape.conv_kernel(shape, 4 * units, kernel_size)
    hidden_kernel_shape = Axon.Shape.conv_kernel(hidden_state_shape, 4 * units, kernel_size)
    bias_shape = Axon.Shape.conv_bias(shape, 4 * units, kernel_size)

    output_shape = Axon.Shape.rnn(shape, units, "ConvLSTM")

    kernel_initializer = opts[:kernel_initializer] || :glorot_uniform
    recurrent_initializer = opts[:recurrent_initializer] || :glorot_uniform
    bias_initializer = opts[:bias_initializer] || :zeros

    wi = param("wi", input_kernel_shape, initializer: kernel_initializer)
    wh = param("wh", hidden_kernel_shape, initializer: kernel_initializer)
    b = param("b", bias_shape, initializer: bias_initializer)

    output =
      layer(
        x,
        :conv_lstm,
        {{hidden_state_shape, hidden_state_shape}, output_shape},
        %{"wi" => wi, "wh" => wh, "b" => b},
        opts[:name],
        strides: strides,
        padding: padding,
        hidden_state: hidden_state,
        hidden_state_shape: hidden_state_shape,
        recurrent_initializer: recurrent_initializer,
        unroll: unroll
      )

    new_c = layer(output, fn x, _ -> elem(elem(x, 0), 0) end, hidden_state_shape, %{})
    new_h = layer(output, fn x, _ -> elem(elem(x, 0), 1) end, hidden_state_shape, %{})
    output_sequence = layer(output, fn x, _ -> elem(x, 1) end, output_shape, %{})

    {{new_c, new_h}, output_sequence}
  end

  @doc """
  Freezes parameters returned from `fun` in the given
  model. `fun` takes the model's parameter list and returns
  the list of parameters it wishes to freeze. `fun` defaults
  to the identity function, freezing all of the parameters in
  `model`.

  Freezing parameters is useful when performing transfer learning
  to leverage features learned from another problem in a new problem.
  For example, it's common to combine the convolutional base from
  larger models trained on ImageNet with fresh fully-connected classifiers.
  The combined model is then trained on fresh data, with the convolutional
  base frozen so as not to lose information. You can see this example in code
  here:

      cnn_base = get_pretrained_cnn_base()
      model =
        cnn_base
        |> Axon.freeze()
        |> Axon.flatten()
        |> Axon.dense(1024, activation: :relu)
        |> Axon.dropout()
        |> Axon.dense(1000, activation: :softmax)

      model
      |> Axon.Training.step(:categorical_cross_entropy, Axon.Optimizers.adam(0.005))
      |> Axon.Training.train(input, targets, epochs: 10)

  When compiled, frozen parameters are wrapped in `Nx.Defn.Kernel.stop_grad/1`,
  which zeros out the gradient with respect to the frozen parameter. Gradients
  of frozen parameters will return `0.0`, meaning they won't be changed during
  the update process.

  """
  def freeze(%Axon{} = model, fun \\ & &1) when is_function(fun, 1) do
    parameters =
      model
      |> get_params([])
      |> Enum.uniq()

    parameters_to_freeze = fun.(parameters)
    do_freeze(model, parameters_to_freeze)
  end

  defp get_params(model, acc) when is_tuple(model) do
    model
    |> Tuple.to_list()
    |> Enum.reduce(acc, &get_params/2)
  end

  defp get_params(%Axon{op: :input}, acc), do: acc

  defp get_params(%Axon{parent: x}, acc) when is_list(x) do
    Enum.reduce(x, acc, &get_params/2)
  end

  defp get_params(%Axon{parent: x, params: params, opts: opts}, acc) do
    acc =
      case opts[:hidden_state] do
        state when is_tuple(state) ->
          state
          |> Tuple.to_list()
          |> Enum.reduce(acc, &get_params/2)

        nil ->
          acc
      end

    get_params(x, Enum.reduce(Map.values(params), acc, fn x, ls -> [x | ls] end))
  end

  defp do_freeze(%Axon{op: :input} = x, _), do: x

  defp do_freeze(%Axon{parent: parent} = x, parameters_to_freeze) when is_list(parent) do
    parent = Enum.map(parent, &do_freeze(&1, parameters_to_freeze))
    %{x | parent: parent}
  end

  defp do_freeze(%Axon{parent: parent, params: params} = x, parameters_to_freeze) do
    parent = do_freeze(parent, parameters_to_freeze)

    params =
      params
      |> Map.new(fn {k, %{name: param_name} = v} ->
        if Enum.any?(parameters_to_freeze, fn %{name: name} -> name == param_name end) do
          {k, %{v | frozen: true}}
        else
          {k, v}
        end
      end)

    %{x | parent: parent, params: params}
  end

  defp do_freeze(x, parameters_to_freeze) when is_tuple(x) do
    x
    |> Tuple.to_list()
    |> Enum.map(&do_freeze(&1, parameters_to_freeze))
  end

  @doc """
  Compiles the given model to `{init_fn, predict_fn}`.
  """
  @doc type: :compilation
  def compile(model) do
    Axon.Compiler.__compile__(model)
  end

  @doc """
  Compiles and runs the given models initialization function
  with the given compiler options.
  """
  @doc type: :execution
  defmacro init(model, opts \\ []) do
    define_init(model, :init, [], opts)
  end

  @doc """
  Compiles and runs the given Axon model with `params` on
  `input` with the given compiler options.
  """
  @doc type: :execution
  defmacro predict(model, params, input, opts \\ []) do
    define_predict(model, :predict, [params, input], opts)
  end

  @doc """
  Compiles and runs the given Axon model's penalty function
  on `params` with the given compiler options.
  """
  @doc type: :execution
  defmacro penalty(model, params, opts \\ []) do
    define_penalty(model, :penalty, [params], opts)
  end

  ## Implementation

  defp define_init(model, caller, args, opts \\ []) do
    quote do
      Nx.Defn.Kernel.transform(unquote(args), fn args ->
        model = unquote(model)
        opts = unquote(opts)
        caller = unquote(caller)

        Axon.Compiler.__jit_init__(model, caller, args, opts)
      end)
    end
  end

  defp define_predict(model, caller, args, opts \\ []) do
    quote do
      Nx.Defn.Kernel.transform(unquote(args), fn args ->
        model = unquote(model)
        opts = unquote(opts)
        caller = unquote(caller)

        Axon.Compiler.__jit_predict__(model, caller, args, opts)
      end)
    end
  end

  defp define_penalty(model, caller, args, opts \\ []) do
    quote do
      Nx.Defn.Kernel.transform(unquote(args), fn args ->
        model = unquote(model)
        opts = unquote(opts)
        caller = unquote(caller)

        Axon.Compiler.__jit_penalty__(model, caller, args, opts)
      end)
    end
  end

  ## Inspection

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(axon, _opts) do
      title = "Model"
      header = ["Layer", "Shape", "Parameters"]
      {_, cache} = axon_to_rows(axon, %{})

      rows =
        cache
        |> Enum.sort()
        |> Enum.unzip()
        |> Kernel.elem(1)

      rows
      |> TableRex.Table.new(header, title)
      |> TableRex.Table.render!(
        header_separator_symbol: "=",
        title_separator_symbol: "=",
        vertical_style: :off
      )
      |> string()
    end

    defp axon_to_rows(%{id: id} = graph, cache) do
      case cache do
        %{^id => row} ->
          {row, cache}

        %{} ->
          {row, cache} = do_axon_to_rows(graph, cache)
          cache = Map.put(cache, id, row)
          {row, cache}
      end
    end

    defp do_axon_to_rows(%Axon{op: op, parent: parents, name: name, output_shape: shape}, cache)
         when is_list(parents) do
      {names, cache} =
        Enum.map_reduce(parents, cache, fn %Axon{name: name} = graph, cache ->
          {_, cache} = axon_to_rows(graph, cache)
          {name, cache}
        end)

      row = [name <> " ( #{Atom.to_string(op)} #{inspect(names)} )", "#{inspect(shape)}", 0]

      {row, cache}
    end

    defp do_axon_to_rows(
           %Axon{op: op, params: params, parent: parent, name: name, output_shape: shape},
           cache
         ) do
      cache =
        if parent do
          {_, cache} = axon_to_rows(parent, cache)
          cache
        else
          cache
        end

      num_params =
        params
        |> Enum.reduce(0, fn {_, %Axon.Parameter{shape: shape}}, acc -> acc + Nx.size(shape) end)

      row = [name <> " ( #{Atom.to_string(op)} )", "#{inspect(shape)}", "#{num_params}"]
      {row, cache}
    end
  end

  ## Helpers

  @valid_initializers [:zeros, :ones, :uniform, :normal, :identity] ++
                        [:lecun_uniform, :lecun_normal, :he_uniform, :he_normal] ++
                        [:glorot_uniform, :glorot_normal, :variance_scaling]

  defp validate_initializer!(initializer)
       when is_atom(initializer) and initializer in @valid_initializers do
    :ok
  end

  defp validate_initializer!(initializer) when is_function(initializer, 1) do
    :ok
  end

  defp validate_initializer!(initializer) do
    raise ArgumentError,
          "initializer must be one of #{inspect(@valid_initializers)}," <>
            " or an arity-1 function accepting initializer options" <>
            " got #{inspect(initializer)}"
  end

  @valid_regularizers [:l1, :l2, :l1l2, :none]

  defp validate_regularizer!(regularizer)
       when is_atom(regularizer) and regularizer in @valid_regularizers do
    :ok
  end

  defp validate_regularizer!(regularizer) when is_function(regularizer) do
    :ok
  end

  defp validate_regularizer!(regularizer) do
    raise ArgumentError,
          "regularizer must be one of #{inspect(@valid_regularizers)}," <>
            " or a function accepting a parameter to regularize," <>
            " got #{inspect(regularizer)}"
  end

  defp tuple_or_duplicate(key, tuple_or_integer, rank) do
    cond do
      is_tuple(tuple_or_integer) ->
        if tuple_size(tuple_or_integer) != rank do
          raise ArgumentError,
                "expected #{inspect(key)} to be a #{rank}-element tuple, " <>
                  "got: #{inspect(tuple_or_integer)}"
        end

        tuple_or_integer

      is_integer(tuple_or_integer) ->
        Tuple.duplicate(tuple_or_integer, rank)

      true ->
        raise ArgumentError,
              "expected #{inspect(key)} to be an integer or a tuple, " <>
                "got: #{inspect(tuple_or_integer)}"
    end
  end

  defp list_or_duplicate(key, list_or_integer, rank) do
    cond do
      is_list(list_or_integer) ->
        if length(list_or_integer) != rank do
          raise ArgumentError,
                "expected #{inspect(key)} to be a #{rank}-element list, " <>
                  "got: #{inspect(list_or_integer)}"
        end

        list_or_integer

      is_integer(list_or_integer) ->
        List.duplicate(list_or_integer, rank)

      true ->
        raise ArgumentError,
              "expected #{inspect(key)} to be an integer or a list, " <>
                "got: #{inspect(list_or_integer)}"
    end
  end

  defp unique_identifiers(type, nil) do
    id = System.unique_integer([:positive, :monotonic])
    {id, Atom.to_string(type) <> "_#{id}"}
  end

  defp unique_identifiers(_type, name), do: {System.unique_integer([:positive, :monotonic]), name}
end
