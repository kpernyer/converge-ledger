defmodule ConvergeLedger.Integrity.MerkleTree do
  @moduledoc """
  Merkle tree implementation for cryptographic integrity verification.

  A Merkle tree is a binary tree of hashes where:
  - Leaf nodes contain hashes of data items
  - Internal nodes contain hashes of their children
  - The root hash represents the integrity of all data

  ## Use Cases

  - **Snapshot verification**: Detect corruption before loading
  - **Efficient sync**: Identify which entries differ between replicas
  - **Audit proofs**: Prove an entry exists without revealing all entries
  - **Tamper detection**: Any change to data changes the root hash

  ## Usage

      iex> entries = [entry1, entry2, entry3]
      iex> hashes = Enum.map(entries, &MerkleTree.hash_entry/1)
      iex> root = MerkleTree.compute_root(hashes)
      iex> MerkleTree.to_hex(root)
      "a1b2c3d4..."

  ## Properties

  - Deterministic: Same inputs → same root hash
  - Collision-resistant: Different inputs → different root hash (with high probability)
  - Single-element trees: Hash is combined with itself (Bitcoin-style)
  """

  alias ConvergeLedger.Entry

  @type hash :: binary()
  @type proof :: [{:left | :right, hash()}]

  @doc """
  Computes the SHA-256 hash of binary content.
  """
  @spec hash(binary()) :: hash()
  def hash(content) when is_binary(content) do
    :crypto.hash(:sha256, content)
  end

  @doc """
  Computes the hash of an Entry.

  Combines context_id, key, payload, sequence, and appended_at_ns
  into a deterministic hash.
  """
  @spec hash_entry(Entry.t()) :: hash()
  def hash_entry(%Entry{} = entry) do
    # Deterministic serialization of entry fields
    content =
      :erlang.term_to_binary([
        entry.context_id,
        entry.key,
        entry.payload,
        entry.sequence,
        entry.appended_at_ns
      ])

    hash(content)
  end

  @doc """
  Combines two hashes into a parent hash (for internal tree nodes).
  """
  @spec combine(hash(), hash()) :: hash()
  def combine(left, right) when is_binary(left) and is_binary(right) do
    hash(left <> right)
  end

  @doc """
  Computes the Merkle root from a list of leaf hashes.

  Uses standard binary Merkle tree construction:
  - Empty list: returns hash of empty binary
  - Single element: combined with itself (Bitcoin-style)
  - Multiple elements: build tree bottom-up

  ## Examples

      iex> MerkleTree.compute_root([])
      <<227, 176, 196, ...>>  # hash of ""

      iex> h = MerkleTree.hash("data")
      iex> MerkleTree.compute_root([h])
      MerkleTree.combine(h, h)  # single element duplicated
  """
  @spec compute_root([hash()]) :: hash()
  def compute_root([]), do: hash("")

  def compute_root([single]) do
    # Single element: combine with itself (Bitcoin-style Merkle tree)
    combine(single, single)
  end

  def compute_root(hashes) when is_list(hashes) do
    build_tree_level(hashes)
  end

  @doc """
  Computes the Merkle root from a list of entries.

  Entries are hashed and then combined into a tree.
  """
  @spec compute_root_from_entries([Entry.t()]) :: hash()
  def compute_root_from_entries(entries) when is_list(entries) do
    entries
    |> Enum.map(&hash_entry/1)
    |> compute_root()
  end

  @doc """
  Verifies that a computed root matches an expected root.
  """
  @spec verify_root([hash()], hash()) :: boolean()
  def verify_root(hashes, expected_root) do
    compute_root(hashes) == expected_root
  end

  @doc """
  Verifies entries against an expected Merkle root.
  """
  @spec verify_entries([Entry.t()], hash()) :: boolean()
  def verify_entries(entries, expected_root) do
    compute_root_from_entries(entries) == expected_root
  end

  @doc """
  Generates a Merkle proof for a leaf at the given index.

  The proof contains the sibling hashes needed to recompute the root.
  Returns `{:ok, proof}` or `{:error, :invalid_index}`.
  """
  @spec generate_proof([hash()], non_neg_integer()) :: {:ok, proof()} | {:error, :invalid_index}
  def generate_proof(hashes, index) when is_list(hashes) and is_integer(index) do
    if index < 0 or index >= length(hashes) do
      {:error, :invalid_index}
    else
      {:ok, do_generate_proof(hashes, index, [])}
    end
  end

  @doc """
  Verifies a Merkle proof for a leaf hash.

  Given a leaf hash, its proof (sibling hashes), and the expected root,
  verifies that the leaf is indeed part of the tree.
  """
  @spec verify_proof(hash(), proof(), hash()) :: boolean()
  def verify_proof(leaf_hash, proof, expected_root) do
    computed_root =
      Enum.reduce(proof, leaf_hash, fn {side, sibling_hash}, current ->
        case side do
          :left -> combine(sibling_hash, current)
          :right -> combine(current, sibling_hash)
        end
      end)

    computed_root == expected_root
  end

  @doc """
  Converts a hash to a hexadecimal string.
  """
  @spec to_hex(hash()) :: String.t()
  def to_hex(hash) when is_binary(hash) do
    Base.encode16(hash, case: :lower)
  end

  @doc """
  Converts a hexadecimal string to a hash.
  """
  @spec from_hex(String.t()) :: {:ok, hash()} | {:error, :invalid_hex}
  def from_hex(hex) when is_binary(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, hash} -> {:ok, hash}
      :error -> {:error, :invalid_hex}
    end
  end

  @doc """
  Returns a short form of the hash for display (first 16 hex chars).
  """
  @spec to_short_hex(hash()) :: String.t()
  def to_short_hex(hash) when is_binary(hash) do
    hash |> to_hex() |> String.slice(0, 16)
  end

  # Private functions

  defp build_tree_level([root]), do: root

  defp build_tree_level(level) do
    level
    |> Enum.chunk_every(2)
    |> Enum.map(fn
      [left, right] -> combine(left, right)
      [single] -> combine(single, single)
    end)
    |> build_tree_level()
  end

  defp do_generate_proof([_single], _index, proof), do: Enum.reverse(proof)

  defp do_generate_proof(hashes, index, proof) do
    # Build the next level and track which sibling we need
    {next_level, new_proof} = build_level_with_proof(hashes, index, proof)
    next_index = div(index, 2)
    do_generate_proof(next_level, next_index, new_proof)
  end

  defp build_level_with_proof(hashes, target_index, proof) do
    {next_level, new_proof, _} =
      hashes
      |> Enum.chunk_every(2)
      |> Enum.reduce({[], proof, 0}, fn chunk, {level, acc_proof, pair_index} ->
        {combined, updated_proof} =
          case chunk do
            [left, right] ->
              # Check if target is in this pair
              proof_entry =
                cond do
                  target_index == pair_index * 2 -> {:right, right}
                  target_index == pair_index * 2 + 1 -> {:left, left}
                  true -> nil
                end

              new_proof = if proof_entry, do: [proof_entry | acc_proof], else: acc_proof
              {combine(left, right), new_proof}

            [single] ->
              # Odd element - duplicate
              proof_entry =
                if target_index == pair_index * 2 do
                  {:right, single}
                else
                  nil
                end

              new_proof = if proof_entry, do: [proof_entry | acc_proof], else: acc_proof
              {combine(single, single), new_proof}
          end

        {[combined | level], updated_proof, pair_index + 1}
      end)

    {Enum.reverse(next_level), new_proof}
  end
end
