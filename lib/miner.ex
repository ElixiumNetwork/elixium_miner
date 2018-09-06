defmodule Miner do
  alias Elixium.Blockchain
  alias Elixium.Blockchain.Block
  alias Elixium.Validator
  alias Elixium.Store.Ledger
  alias Elixium.Transaction
  alias Elixium.Store.Utxo
  alias Elixium.Utilities
  alias Elixium.Error
  alias Elixium.P2P.Peer
  alias Decimal, as: D

  @index_space 10
  @nonce_space 10
  @elapsed_space 10

  def initialize(address) do
    Ledger.initialize()
    Utxo.initialize()
    chain = Blockchain.initialize()

    p2p_supervisor = Peer.initialize

    main(chain, address, List.first(chain).difficulty, p2p_supervisor)
  end

  def main(chain, address, difficulty, p2p_supervisor) do
    # Wait until we're connected to at least one peer
    if p2p_supervisor |> Peer.connected_handlers() |> length == 0 do
      main(chain, address, difficulty, p2p_supervisor)
    end

    block =
      List.first(chain)
      |> Block.initialize()

    difficulty =
      if rem(block.index, Blockchain.diff_rebalance_offset()) == 0 do
        new_difficulty = Blockchain.recalculate_difficulty(chain) + difficulty
        IO.puts("Difficulty recalculated! Changed from #{difficulty} to #{new_difficulty}")
        new_difficulty
      else
        difficulty
      end

    block = %{block | difficulty: difficulty}

    IO.write("Mining block #{block.index}...\r")

    before = :os.system_time()

    block =
      block
      |> calculate_coinbase_amount
      |> Transaction.generate_coinbase(address)
      |> merge_block(block)
      |> Block.mine()

    blue = "\e[34m"
    clear = "\e[0m"
    elapsed = (:os.system_time() - before) / 1_000_000_000

    index_str = "#{blue}Index:#{clear} #{String.pad_trailing(inspect(block.index), @index_space)}"
    hash_str = "#{blue}Hash:#{clear} #{block.hash}"
    nonce_str = "#{blue}Nonce:#{clear} #{String.pad_trailing(inspect(block.nonce), @nonce_space)}"

    elapsed_str =
      "#{blue}Elapsed (s):#{clear} #{String.pad_trailing(inspect(elapsed), @elapsed_space)}"

    hashrate_str = "#{blue}Hashrate (H/s):#{clear} #{round(block.nonce / elapsed)}"

    IO.puts("#{index_str} #{hash_str} #{nonce_str} #{elapsed_str} #{hashrate_str}")

    case Validator.is_block_valid?(block, chain, difficulty) do
      :ok ->
        distribute_block(block, p2p_supervisor)
        main(Blockchain.add_block(chain, block), address, difficulty, p2p_supervisor)

      err ->
        IO.puts(Error.to_string(err))
        main(chain, address, difficulty, p2p_supervisor)
    end
  end

  @spec calculate_coinbase_amount(Block) :: Decimal
  defp calculate_coinbase_amount(block) do
    D.add(Block.calculate_block_reward(block.index), Block.total_block_fees(block.transactions))
  end

  defp merge_block(coinbase, block) do
    new_transactions = [coinbase | block.transactions]
    txoids = Enum.map(new_transactions, & &1.id)

    Map.merge(block, %{
      transactions: new_transactions,
      merkle_root: Utilities.calculate_merkle_root(txoids)
    })
  end

  defp distribute_block(block, p2p_supervisor) do
    p2p_supervisor
    |> Peer.connected_handlers()
    |> Enum.each(&send(&1, {"BLOCK", block}))
  end
end
