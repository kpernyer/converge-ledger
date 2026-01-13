defmodule ConvergeLedger.Integrity.LamportClock do
  @moduledoc """
  Lamport logical clock for causal ordering of events.

  Lamport clocks provide a partial ordering of events in a distributed system
  without requiring synchronized wall clocks. The key property is:
  if event A happened-before event B, then `clock(A) < clock(B)`.

  ## Usage

      iex> clock = LamportClock.new()
      iex> {clock, t1} = LamportClock.tick(clock)
      iex> t1
      1
      iex> {clock, t2} = LamportClock.tick(clock)
      iex> t2
      2
      iex> {clock, t3} = LamportClock.update(clock, 10)
      iex> t3
      11

  ## Properties

  - Monotonic: Clock value never decreases
  - Consistent: Same input → same output
  - Causal: `happened_before?(a, b)` implies `clock(a) < clock(b)`
  """

  @type t :: %__MODULE__{
          time: non_neg_integer()
        }

  defstruct time: 0

  @doc """
  Creates a new Lamport clock initialized to 0.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{time: 0}

  @doc """
  Creates a Lamport clock with a specific initial time.
  """
  @spec new(non_neg_integer()) :: t()
  def new(initial_time) when is_integer(initial_time) and initial_time >= 0 do
    %__MODULE__{time: initial_time}
  end

  @doc """
  Returns the current logical time.
  """
  @spec time(t()) :: non_neg_integer()
  def time(%__MODULE__{time: time}), do: time

  @doc """
  Increments the clock and returns `{new_clock, new_time}`.

  Called before any local event (e.g., appending an entry).
  """
  @spec tick(t()) :: {t(), non_neg_integer()}
  def tick(%__MODULE__{time: time} = clock) do
    new_time = time + 1
    {%{clock | time: new_time}, new_time}
  end

  @doc """
  Updates the clock based on a received timestamp.

  Sets clock to `max(local, received) + 1`.
  Called when receiving entries from another source.

  Returns `{new_clock, new_time}`.
  """
  @spec update(t(), non_neg_integer()) :: {t(), non_neg_integer()}
  def update(%__MODULE__{time: local_time} = clock, received_time)
      when is_integer(received_time) and received_time >= 0 do
    new_time = max(local_time, received_time) + 1
    {%{clock | time: new_time}, new_time}
  end

  @doc """
  Compares two clock values.

  Returns:
  - `:lt` if a < b (a happened before b, or b is causally later)
  - `:gt` if a > b (b happened before a, or a is causally later)
  - `:eq` if a == b (concurrent events, or same event)
  """
  @spec compare(non_neg_integer(), non_neg_integer()) :: :lt | :gt | :eq
  def compare(a, b) when is_integer(a) and is_integer(b) do
    cond do
      a < b -> :lt
      a > b -> :gt
      true -> :eq
    end
  end

  @doc """
  Returns true if clock value `a` is causally before `b`.

  Note: `a < b` implies `a` may have happened before `b`, but
  the converse is not guaranteed (concurrent events may have any ordering).
  """
  @spec happened_before?(non_neg_integer(), non_neg_integer()) :: boolean()
  def happened_before?(a, b) when is_integer(a) and is_integer(b), do: a < b

  @doc """
  Merges two clocks, returning the maximum of both.

  Useful when combining state from multiple sources.
  """
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{time: a}, %__MODULE__{time: b}) do
    %__MODULE__{time: max(a, b)}
  end
end
