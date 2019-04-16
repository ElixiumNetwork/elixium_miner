defmodule Miner.BlockCalculator do
  use GenServer
  require IEx
  require Logger
  alias Miner.BlockCalculator.Mine
  alias Elixium.Validator
  alias Elixium.Transaction
  alias Elixium.Store.Ledger
  alias Elixium.Store.Oracle
  alias Elixium.Error

  def start_link(address) do
    GenServer.start_link(__MODULE__, address, name: __MODULE__)
  end

  def init(address) do
    Process.send_after(self(), :start, 1000)

    {:ok, %{address: address, transactions: [], currently_mining: [], mine_task: []}}
  end

  @doc """
    Tell the block calculator to stop mining the block it's working on. This is
    usually called when we've received a new block at the index that we're
    currently mining at; we don't want to continue mining an old block, so we
    start over on a new block.
  """
  def interrupt_mining, do: GenServer.cast(__MODULE__, :interrupt)

  @doc """
    Starts the mining task to mine the next block in the chain.
  """
  def start_mining, do: GenServer.cast(__MODULE__, :start)

  @doc """
    Called pretty much exclusively by the mine task to signal that it has found
    a suitable hash. This will distribute the block to known peers and start a
    task to mine the next block.
  """
  def finished_mining(block), do: GenServer.cast(__MODULE__, {:hash_found, block})

  @doc """
    Tell the block calculator to stop mining the block it's working on and start
    a new task. This is usually called when we've received a new block at the
    index that we're currently mining at; we don't want to continue mining an
    old block, so we start over on a new block.
  """
  def restart_mining, do: GenServer.cast(__MODULE__, :restart)

  def add_tx_to_pool(tx), do: GenServer.cast(__MODULE__, {:add_transaction_to_pool, tx})

  def transaction_pool, do: GenServer.call(__MODULE__, :get_transaction_pool)

  def remove_transactions_from_pool(transactions) do
    GenServer.cast(__MODULE__, {:remove_transactions_from_pool, transactions})
  end

  def handle_info(:start, state) do
    start_mining()
    {:noreply, state}
  end

  def handle_call(:get_transaction_pool, _from, state) do
    {:reply, state.transactions, state}
  end

  def handle_cast(:interrupt, state) do
    Enum.each(state.mine_task, & Process.exit(&1, :mine_interrupt))

    state = Map.put(state, :mine_task, [])
    {:noreply, state}
  end

  def handle_cast(:start, state) do
    {:ok, pid} = Mine.start(state.address, find_favorable_transactions(state.transactions))

    state = Map.put(state, :mine_task, [pid | state.mine_task])
    {:noreply, state}
  end

  def handle_cast(:restart, state) do
    Enum.each(state.mine_task, & Process.exit(&1, :mine_interrupt))

    {:ok, pid} = Mine.start(state.address, find_favorable_transactions(state.transactions))

    state = Map.put(state, :mine_task, [pid | state.mine_task])

    {:noreply, state}
  end

  def handle_cast({:hash_found, block}, state) do
    case Validator.is_block_valid?(block, block.difficulty) do
      :ok ->
        remove_transactions_from_pool(state.currently_mining)
        Ledger.append_block(block)
        Oracle.inquire(:"Elixir.Elixium.Store.UtxoOracle", {:update_with_transactions, [block.transactions]})
        Pico.broadcast("BLOCK", block)
        start_mining()

      err ->
        Logger.error("Calculated hash for new block, but didn't pass validation:")

        err
        |> Error.to_string()
        |> Logger.error()

        start_mining()
    end

    {:noreply, state}
  end

  def handle_cast({:update_currently_mining_txs, transactions}, state) do
    {:noreply, %{state | currently_mining: transactions}}
  end

  def handle_cast({:add_transaction_to_pool, transaction}, state) do
    # Check if we've already received a transaction that has a utxo that is
    # being used within this transaction. We'll ignore this transaction if we
    # have, since this would be a double spend
    inputs_in_pool? =
      state.transactions
      |> Enum.flat_map(& &1.inputs)
      |> Enum.any?(fn pool_utxo ->
        Enum.any?(transaction.inputs, & &1 == pool_utxo)
      end)

    state =
      if !inputs_in_pool? do
        %{state | transactions: [transaction | state.transactions]}
      else
        state
      end

    {:noreply, state}
  end

  def handle_cast({:remove_transactions_from_pool, transactions}, state) do
    txids = Enum.map(transactions, & &1.id)

    remove = Enum.filter(state.transactions, & &1.id in txids)

    transactions = state.transactions -- remove

    {:noreply, %{state | transactions: transactions}}
  end

  defp find_favorable_transactions(transaction_pool) do
    block_size_limit = Application.get_env(:elixium_core, :block_size_limit)
    header_size = 224

    # Varies, but 500 is the maximum size it will be. We should look into a way
    # of getting the exact size.
    coinbase_size = 500

    remaining_space = block_size_limit - header_size - coinbase_size

    txs =
      transaction_pool
      |> Enum.sort(& Transaction.calculate_fee(&1) >= Transaction.calculate_fee(&2))
      |> fit_transactions([], remaining_space)

    GenServer.cast(__MODULE__, {:update_currently_mining_txs, txs})

    txs
  end

  # Fits as many transactions as possible into the block
  defp fit_transactions([], transactions, _remaining_space), do: transactions

  defp fit_transactions([transaction | remaining_transactions], transactions, remaining_space) do
    tx_bytes =
      transaction
      |> :erlang.term_to_binary()
      |> byte_size()

    if remaining_space >= tx_bytes do
      fit_transactions(remaining_transactions, [transaction | transactions], remaining_space - tx_bytes)
    else
      fit_transactions(remaining_transactions, transactions, remaining_space)
    end
  end
end
