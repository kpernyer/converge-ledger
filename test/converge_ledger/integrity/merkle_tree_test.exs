defmodule ConvergeLedger.Integrity.MerkleTreeTest do
  use ExUnit.Case, async: true

  alias ConvergeLedger.Entry
  alias ConvergeLedger.Integrity.MerkleTree

  describe "compute_root/1" do
    test "empty list returns hash of empty string" do
      root = MerkleTree.compute_root([])
      assert is_binary(root)
      assert byte_size(root) == 32
    end

    test "single element duplicates itself (Bitcoin-style)" do
      hash = MerkleTree.hash("data")
      root = MerkleTree.compute_root([hash])
      expected = MerkleTree.combine(hash, hash)
      assert root == expected
    end

    test "two elements combine directly" do
      h1 = MerkleTree.hash("first")
      h2 = MerkleTree.hash("second")
      root = MerkleTree.compute_root([h1, h2])
      expected = MerkleTree.combine(h1, h2)
      assert root == expected
    end

    test "deterministic - same inputs produce same root" do
      hashes = for i <- 1..10, do: MerkleTree.hash("data-#{i}")
      root1 = MerkleTree.compute_root(hashes)
      root2 = MerkleTree.compute_root(hashes)
      assert root1 == root2
    end

    test "different inputs produce different roots" do
      hashes1 = for i <- 1..5, do: MerkleTree.hash("data-#{i}")
      hashes2 = for i <- 1..5, do: MerkleTree.hash("other-#{i}")
      root1 = MerkleTree.compute_root(hashes1)
      root2 = MerkleTree.compute_root(hashes2)
      assert root1 != root2
    end
  end

  describe "tamper detection - the key benefit" do
    test "detects single byte change in any entry" do
      entries = create_test_entries(10)
      original_root = MerkleTree.compute_root_from_entries(entries)

      # Tamper with the middle entry's payload
      tampered =
        List.update_at(entries, 5, fn entry ->
          %{entry | payload: entry.payload <> "x"}
        end)

      tampered_root = MerkleTree.compute_root_from_entries(tampered)
      assert original_root != tampered_root, "Merkle root should change when any entry is modified"
    end

    test "detects entry reordering" do
      entries = create_test_entries(5)
      original_root = MerkleTree.compute_root_from_entries(entries)

      # Swap two entries
      [a, b, c, d, e] = entries
      reordered = [a, d, c, b, e]
      reordered_root = MerkleTree.compute_root_from_entries(reordered)

      assert original_root != reordered_root, "Merkle root should change when entries are reordered"
    end

    test "detects entry deletion" do
      entries = create_test_entries(10)
      original_root = MerkleTree.compute_root_from_entries(entries)

      # Remove an entry
      deleted = List.delete_at(entries, 3)
      deleted_root = MerkleTree.compute_root_from_entries(deleted)

      assert original_root != deleted_root, "Merkle root should change when entries are deleted"
    end

    test "detects entry insertion" do
      entries = create_test_entries(10)
      original_root = MerkleTree.compute_root_from_entries(entries)

      # Insert an entry
      new_entry = create_entry("ctx", "key", "new-payload", 999)
      inserted = List.insert_at(entries, 5, new_entry)
      inserted_root = MerkleTree.compute_root_from_entries(inserted)

      assert original_root != inserted_root, "Merkle root should change when entries are inserted"
    end

    test "unchanged entries produce same root - integrity verification" do
      entries = create_test_entries(100)
      root1 = MerkleTree.compute_root_from_entries(entries)

      # Simulate storing and retrieving (no changes)
      retrieved_entries = entries
      root2 = MerkleTree.compute_root_from_entries(retrieved_entries)

      assert root1 == root2, "Same entries should always produce same Merkle root"
    end
  end

  describe "verify_entries/2 for snapshot verification" do
    test "verifies valid entries match expected root" do
      entries = create_test_entries(20)
      root = MerkleTree.compute_root_from_entries(entries)

      assert MerkleTree.verify_entries(entries, root)
    end

    test "rejects tampered entries" do
      entries = create_test_entries(20)
      root = MerkleTree.compute_root_from_entries(entries)

      tampered =
        List.update_at(entries, 10, fn entry ->
          %{entry | payload: "tampered!"}
        end)

      refute MerkleTree.verify_entries(tampered, root),
             "Verification should fail for tampered entries"
    end
  end

  describe "generate_proof/2 and verify_proof/3 - audit trail" do
    test "generates valid proof for any leaf" do
      hashes = for i <- 1..8, do: MerkleTree.hash("data-#{i}")
      root = MerkleTree.compute_root(hashes)

      for index <- 0..7 do
        {:ok, proof} = MerkleTree.generate_proof(hashes, index)
        leaf = Enum.at(hashes, index)
        assert MerkleTree.verify_proof(leaf, proof, root),
               "Proof should be valid for leaf at index #{index}"
      end
    end

    test "proof for one leaf doesn't work for another" do
      hashes = for i <- 1..4, do: MerkleTree.hash("data-#{i}")
      root = MerkleTree.compute_root(hashes)

      {:ok, proof_for_0} = MerkleTree.generate_proof(hashes, 0)
      leaf_1 = Enum.at(hashes, 1)

      refute MerkleTree.verify_proof(leaf_1, proof_for_0, root),
             "Proof for one leaf should not verify another leaf"
    end

    test "can prove entry existence without revealing other entries" do
      entries = create_test_entries(100)
      hashes = Enum.map(entries, &MerkleTree.hash_entry/1)
      root = MerkleTree.compute_root(hashes)

      # Prove entry 42 exists
      target_index = 42
      {:ok, proof} = MerkleTree.generate_proof(hashes, target_index)
      target_hash = Enum.at(hashes, target_index)

      # The proof only contains log2(n) hashes, not all entries
      assert length(proof) == 7  # log2(100) rounded up
      assert MerkleTree.verify_proof(target_hash, proof, root)
    end
  end

  describe "hex conversion" do
    test "round-trips hash to hex and back" do
      original = MerkleTree.hash("test data")
      hex = MerkleTree.to_hex(original)
      {:ok, decoded} = MerkleTree.from_hex(hex)
      assert original == decoded
    end

    test "produces lowercase hex" do
      hash = MerkleTree.hash("test")
      hex = MerkleTree.to_hex(hash)
      assert hex == String.downcase(hex)
    end

    test "short hex is first 16 chars" do
      hash = MerkleTree.hash("test")
      short = MerkleTree.to_short_hex(hash)
      full = MerkleTree.to_hex(hash)
      assert short == String.slice(full, 0, 16)
    end
  end

  # Helper functions

  defp create_test_entries(count) do
    for i <- 1..count do
      create_entry("test-context", "key-#{i}", "payload-#{i}", i)
    end
  end

  defp create_entry(context_id, key, payload, sequence) do
    %Entry{
      id: "entry-#{sequence}",
      context_id: context_id,
      key: key,
      payload: payload,
      sequence: sequence,
      appended_at_ns: 1_000_000_000 + sequence,
      metadata: %{}
    }
  end
end
