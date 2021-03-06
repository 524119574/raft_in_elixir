
# distributed algorithms, n.dulay 4 feb 2020
# coursework, raft consensus, v1

defmodule Monitor do

def notify(s, message), do: send s.config.monitorP, message

def debug(s, string) do
  if s.config.debug_level == 0, do: IO.puts "server #{s.id} in term #{Map.get(s, :curr_term, 0)} #{string}"
end # debug

def debug(s, level, string) do
  if level >= s.config.debug_level do
    IO.puts "server #{s.id} in term #{Map.get(s, :curr_term, 0)} #{string}"
  end
end # debug

def state(s, level, string) do
 if level >= s.config.debug_level  do
    state_out = for {key, value} <- s, into: "" do "\n  #{key}\t #{inspect value}" end
    IO.puts "server #{s.id} #{s.role}: #{inspect s.selfP} #{string} state = #{state_out}"
 end # if
end # state

def halt(string) do
  IO.puts "monitor: #{string}"
  System.stop
end # halt

def halt(s, string) do
  IO.puts "server #{s.id} #{string}"
  System.stop
end # halt

def letter(s, letter) do
  if s.config.debug_level == 3, do: IO.write(letter)
end # letter

def start(config) do
  state = %{
    config:             config,
    clock:              0,
    requests:           Map.new,
    updates:            Map.new,
    moves:              Map.new,
    # rest omitted
  }
  Process.send_after(self(), { :PRINT }, state.config.print_after)
  Monitor.next(state)
end # start

def clock(state, v), do: Map.put(state, :clock, v)

def requests(state, i, v), do:
    Map.put(state, :requests, Map.put(state.requests, i, v))

def updates(state, i, v), do:
    Map.put(state, :updates,  Map.put(state.updates, i, v))

def moves(state, v), do: Map.put(state, :moves, v)

def next(state) do
  receive do
  { :DB_move, db, seqnum, command} ->
    { :move, amount, from, to } = command

    # state.updates format {server_id : num of updates executed by db}
    # state.moves format {seqnum : command} should be the same for all databases?
    done = Map.get(state.updates, db, 0)

    if seqnum != done + 1, do:
       Monitor.halt "  ** error db #{db}: seq #{seqnum} expecting #{done + 1}"

    moves =
      case Map.get(state.moves, seqnum) do
      nil ->
        Map.put state.moves, seqnum, %{ amount: amount, from: from, to: to }

      t -> # already logged - check command
        if amount != t.amount or from != t.from or to != t.to, do:
	  Monitor.halt " ** error db #{db}.#{done} [#{amount}, #{from}, #{to}] " <>
            "= log #{done}/#{map_size(state.moves)} [#{t.amount}, #{t.from}, #{t.to}]"
        # IO.inspect(state.moves)
        state.moves
      end # case

    state = Monitor.moves(state, moves)
    state = Monitor.updates(state, db, seqnum)
    Monitor.next(state)

  { :CLIENT_REQUEST, server_id } ->  # client requests seen by leaders
    # state = Monitor.requests(state, server_id, state.requests + 1)
    # changed this line bc updates not initialized to 0
    state = Monitor.requests(state, server_id, Map.get(state.requests, server_id, 0) + 1)
    Monitor.next(state)

  { :PRINT } ->
    clock  = state.clock + state.config.print_after
    state  = Monitor.clock(state, clock)
    sorted = state.updates  |> Map.to_list |> List.keysort(0)
    IO.puts "time = #{clock}      db updates done = #{inspect sorted}"
    sorted = state.requests |> Map.to_list |> List.keysort(0)
    IO.puts "time = #{clock} client requests seen = #{inspect sorted}"

    if state.config.debug_level >= 0 do  # always
      min_done   = state.updates  |> Map.values |> Enum.min(fn -> 0 end)
      n_requests = state.requests |> Map.values |> Enum.sum
      IO.puts "time = #{clock}           total seen = #{n_requests} max lag = #{n_requests-min_done}"
    end

    IO.puts ""
    Process.send_after(self(), { :PRINT }, state.config.print_after)
    Monitor.next(state)

  # ** ADD ADDITIONAL MONITORING MESSAGES HERE

  unexpected ->
    Monitor.halt "monitor: unexpected message #{inspect unexpected}"
  end # receive
end # next

end # Monitor

