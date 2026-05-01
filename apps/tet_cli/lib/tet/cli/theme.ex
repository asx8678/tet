defmodule Tet.CLI.Theme do
  @moduledoc """
  Theme schema and ANSI rendering for CLI output.

  Themes are purely cosmetic — they control colors and styles for different
  output types but NEVER alter runtime policy, logic, or data flow. A theme
  is a decoration layer applied to rendered output, not a behavioral switch.

  The default theme works in standard terminals that support ANSI escape codes.
  When stdout is not a TTY (piped output), themes are automatically disabled
  to avoid injecting escape codes into piped data.
  """

  @type color :: atom() | String.t()
  @type style :: atom() | String.t()

  @type t :: %__MODULE__{
          name: String.t(),
          heading: style_spec(),
          label: style_spec(),
          value: style_spec(),
          error: style_spec(),
          success: style_spec(),
          muted: style_spec(),
          accent: style_spec(),
          reset: String.t()
        }

  @type style_spec :: %{
          fg: color(),
          bg: color(),
          bold: boolean(),
          dim: boolean(),
          italic: boolean()
        }

  defstruct [
    :name,
    heading: %{fg: :cyan, bg: :default, bold: true, dim: false, italic: false},
    label: %{fg: :green, bg: :default, bold: false, dim: false, italic: false},
    value: %{fg: :default, bg: :default, bold: false, dim: false, italic: false},
    error: %{fg: :red, bg: :default, bold: true, dim: false, italic: false},
    success: %{fg: :green, bg: :default, bold: true, dim: false, italic: false},
    muted: %{fg: :default, bg: :default, bold: false, dim: true, italic: false},
    accent: %{fg: :yellow, bg: :default, bold: false, dim: false, italic: false},
    reset: "\e[0m"
  ]

  @doc "Returns the default terminal theme."
  @spec default() :: t()
  def default, do: %__MODULE__{name: "default"}

  @doc "Returns a plain theme that emits no ANSI escape codes."
  @spec plain() :: t()
  def plain do
    no_ansi = %{fg: :default, bg: :default, bold: false, dim: false, italic: false}

    %__MODULE__{
      name: "plain",
      heading: no_ansi,
      label: no_ansi,
      value: no_ansi,
      error: no_ansi,
      success: no_ansi,
      muted: no_ansi,
      accent: no_ansi,
      reset: ""
    }
  end

  @doc """
  Resolves the active theme based on the current environment.

  If stdout is a TTY, returns the default theme. Otherwise, returns the
  plain theme to avoid injecting escape codes into piped output.

  The `:force_ansi` option can override TTY detection for testing.
  """
  @spec resolve(keyword()) :: t()
  def resolve(opts \\ []) do
    force_ansi = Keyword.get(opts, :force_ansi)

    case force_ansi do
      true -> default()
      false -> plain()
      nil -> if(tty?(), do: default(), else: plain())
    end
  end

  @doc "Applies a style to text, returning ANSI-escaped string."
  @spec style(t(), atom(), String.t()) :: String.t()
  def style(%__MODULE__{} = theme, style_key, text) when is_atom(style_key) do
    spec = Map.get(theme, style_key) || theme.value
    escape = ansi_escape(spec)
    reset = theme.reset

    case escape do
      nil -> text
      code -> "#{code}#{text}#{reset}"
    end
  end

  @doc "Stylizes a heading (e.g., 'Profiles:', 'Events:')."
  @spec heading(t(), String.t()) :: String.t()
  def heading(%__MODULE__{} = theme, text), do: style(theme, :heading, text)

  @doc "Stylizes a label (e.g., 'session=ses_1')."
  @spec label(t(), String.t()) :: String.t()
  def label(%__MODULE__{} = theme, text), do: style(theme, :label, text)

  @doc "Stylizes a value (default body text)."
  @spec value(t(), String.t()) :: String.t()
  def value(%__MODULE__{} = theme, text), do: style(theme, :value, text)

  @doc "Stylizes an error message."
  @spec error(t(), String.t()) :: String.t()
  def error(%__MODULE__{} = theme, text), do: style(theme, :error, text)

  @doc "Stylizes a success message."
  @spec success(t(), String.t()) :: String.t()
  def success(%__MODULE__{} = theme, text), do: style(theme, :success, text)

  @doc "Stylizes muted/dimmed text."
  @spec muted(t(), String.t()) :: String.t()
  def muted(%__MODULE__{} = theme, text), do: style(theme, :muted, text)

  @doc "Stylizes accent/highlight text."
  @spec accent(t(), String.t()) :: String.t()
  def accent(%__MODULE__{} = theme, text), do: style(theme, :accent, text)

  @doc "Returns the theme as a plain map (for introspection/debug)."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = theme) do
    theme
    |> Map.from_struct()
    |> Map.new(fn {k, v} ->
      {k, (is_struct(v) && is_struct(v, __MODULE__) && to_map(v)) || v}
    end)
  end

  @doc "Validates that a theme struct has all required keys with valid values."
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = theme) do
    style_keys = [:heading, :label, :value, :error, :success, :muted, :accent]

    Enum.reduce_while(style_keys, :ok, fn key, :ok ->
      spec = Map.get(theme, key)

      if valid_style_spec?(spec) do
        {:cont, :ok}
      else
        {:halt, {:error, {:invalid_style_spec, key, spec}}}
      end
    end)
  end

  def validate(_other), do: {:error, :not_a_theme}

  # -- ANSI helpers --

  defp ansi_escape(%{fg: :default, bg: :default, bold: false, dim: false, italic: false}),
    do: nil

  defp ansi_escape(spec) do
    codes =
      []
      |> maybe_add_code(spec.bold, 1)
      |> maybe_add_code(spec.dim, 2)
      |> maybe_add_code(spec.italic, 3)
      |> maybe_add_fg_code(spec.fg)
      |> maybe_add_bg_code(spec.bg)

    if codes == [], do: "", else: "\e[#{Enum.join(codes, ";")}m"
  end

  defp maybe_add_code(codes, true, code), do: codes ++ [code]
  defp maybe_add_code(codes, _false, _code), do: codes

  defp maybe_add_fg_code(codes, :default), do: codes
  defp maybe_add_fg_code(codes, fg) when is_atom(fg), do: codes ++ [fg_ansi(fg)]
  defp maybe_add_fg_code(codes, _fg), do: codes

  defp maybe_add_bg_code(codes, :default), do: codes
  defp maybe_add_bg_code(codes, bg) when is_atom(bg), do: codes ++ [bg_ansi(bg)]
  defp maybe_add_bg_code(codes, _bg), do: codes

  @fg_colors %{
    black: 30,
    red: 31,
    green: 32,
    yellow: 33,
    blue: 34,
    magenta: 35,
    cyan: 36,
    white: 37,
    bright_black: 90,
    bright_red: 91,
    bright_green: 92,
    bright_yellow: 93,
    bright_blue: 94,
    bright_magenta: 95,
    bright_cyan: 96,
    bright_white: 97
  }

  @bg_colors %{
    black: 40,
    red: 41,
    green: 42,
    yellow: 43,
    blue: 44,
    magenta: 45,
    cyan: 46,
    white: 47,
    bright_black: 100,
    bright_red: 101,
    bright_green: 102,
    bright_yellow: 103,
    bright_blue: 104,
    bright_magenta: 105,
    bright_cyan: 106,
    bright_white: 107
  }

  defp fg_ansi(color), do: Map.get(@fg_colors, color, 39)
  defp bg_ansi(color), do: Map.get(@bg_colors, color, 49)

  @supported_fg Map.keys(@fg_colors) ++ [:default]
  @supported_bg Map.keys(@bg_colors) ++ [:default]

  defp valid_style_spec?(%{fg: fg, bg: bg, bold: bold, dim: dim, italic: italic})
       when fg in @supported_fg and
              bg in @supported_bg and
              is_boolean(bold) and is_boolean(dim) and is_boolean(italic),
       do: true

  defp valid_style_spec?(_), do: false

  defp tty? do
    Function.info(System, :builtins) && :io.columns() != :undefined
  rescue
    _ -> false
  end
end
