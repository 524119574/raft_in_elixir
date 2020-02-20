defmodule Leader do

  def start(s) do
    Monitor.debug(s, "I am the leader for term #{s[:curr_term]}")
    s = State.role(s, :LEADER)
    # Initialize next_index and match_index for other servers
    next_index = for server <- s[:servers], server != self(), into: %{}, do: {server, s[:commit_index] + 1}
    match_index = for server <- s[:servers], server != self(), into: %{}, do: {server, 0}
    s = State.next_index(s, next_index)
    s = State.match_index(s, match_index)
    s = State.append_map(s, Map.new)
    # First heartbeat to establish self as leader
    for server <- s[:servers], server != self(), do:
      send(server, {:appendEntry, s[:curr_term], s[:id], 0, 0, nil, s[:commit_index]})
    Process.send_after(self(), {:resendHeartBeat}, 50)

    # leader crash every 5000 ms
    Process.send_after(self(), {:crash_timeout}, 2500)

    # commit uncommitted index in its log
    if Log.getLogSize(s[:log]) > s[:commit_index] do
      IO.puts "Leader encounters previously uncommitted entry"
      num_of_entries = Log.getLogSize(s[:log]) - s[:commit_index]
      # NOTE: last arg client hard coded to self() bc don't know
      append_msgs = Enum.map(1..num_of_entries, fn i ->
        {:appendEntry, s[:curr_term], s[:id],
                      Log.getPrevLogIndex(s[:log]) - i,                  #prevLogIndex
                      s[:log][Log.getPrevLogIndex(s[:log]) - i][:term],  #prevLogTerm
                      [s[:log][Log.getPrevLogIndex(s[:log]) + 1 - i]],
                      s[:commit_index]} end)
      # reverse msgs to send in log entry order
      append_msgs = Enum.reverse(append_msgs)
      # IO.inspect(append_msgs)

      # broadcast appendEntry
      Enum.map(append_msgs, fn msg ->
        for server <- s[:servers], server != self(), do:
          send server, msg
        end)
      # put messages into append_map
      s = Enum.reduce(append_msgs, s, fn msg, s -> State.append_map(s, msg, 1) end)
      IO.inspect(s[:append_map])
      IO.puts "think sent msgs to append prev"
      next(s)
    end
    next(s)
  end

  defp next(s) do

    receive do
      { :crash_timeout } ->
        # Monitor.debug(s, "crashed and will sleep for 2000 ms")
        # Process.sleep(2000)
        # Monitor.debug(s, "leader finished sleeping and restarted")
        # # IO.inspect(s[:log])
        # next(s)
        Monitor.debug(s, "crashed")
        Process.sleep(30_000)

      {:resendHeartBeat} ->
        for server <- s[:servers], server != self(), do:
          send(server, {:appendEntry, s[:curr_term], s[:id],
                        0,   # prevLogIndex
                        0,   # prevLogTerm
                        nil, # entries
                        s[:commit_index]})
        Process.send_after(self(), {:resendHeartBeat}, 50)
        next(s)

      {:CLIENT_REQUEST, %{clientP: client, uid: uid, cmd: cmd}} ->
        # TODO: prevents broadcasting the same request twice (client sends cuz timeout), change into retries indefinitely
        if (!Map.has_key?(s[:commit_log], uid)) do
          Monitor.notify(s, { :CLIENT_REQUEST, s[:id] })
          Monitor.debug(s, "I have received a request from client in term #{s[:curr_term]} cmd is #{inspect(cmd)} uid is #{inspect(uid)}")
          # TODO: ASSUME LEN(ENTRIES) == 1
          prevLog = s[:log]
          # Add the client request to its own log.
          s = State.log(s, Log.appendNewEntry(prevLog, %{term: s[:curr_term], uid: uid, cmd: cmd, clientP: client}))
          s = State.commit_log(s, uid, false)
          Monitor.debug(s, "Leader log updated log length #{Log.getLogSize(s[:log])}")
          appendEntryMsg = {:appendEntry, s[:curr_term], s[:id],
                            Log.getPrevLogIndex(prevLog),
                            Log.getPrevLogTerm(prevLog),
                            [%{term: s[:curr_term], uid: uid, cmd: cmd, clientP: client}],
                            s[:commit_index]}
          # broadcast the appendEntry RPC.
          for server <- s[:servers], server != self(), do:
            send server, appendEntryMsg
          next(s)
        end
        next(s)

      # TODO: retries indefinitely if never received success from follower
      {:appendEntryResponse, term, true, originalMessage, from, matchIndex} ->
        {:appendEntry, term, leaderId, prevLogIndex,
         prevLogTerm, entries, leaderCommit} = originalMessage
        # TODO: update match_index, include in msg; next_index might be INCORRECT
        s = State.next_index(s, from, max(prevLogIndex + 2, s[:next_index][from]))
        s = State.match_index(s, from, max(matchIndex, s[:match_index][from]))

        # RAISE ARITHMATIC ERROR
        # Monitor.debug(s, "append map is: #{inspect(s[:append_map])}")
        # Monitor.debug(s, "original message: #{inspect(originalMessage)}")
        s = State.append_map(s, originalMessage, Map.get(s[:append_map], originalMessage, 1) + 1)
        # check if commit index condition is right
        if s[:append_map][originalMessage] >= s[:majority] and leaderCommit <= s[:commit_index]
        and !s[:commit_log][Enum.at(entries, 0)[:uid]] do
          # Monitor.debug(s, "COMMITED BC append map is: #{s[:append_map][originalMessage]} reaches majority")
          for entry <- entries, do: send s[:databaseP], {:EXECUTE, entry[:cmd]}
          s = State.commit_log(s, Enum.at(entries, 0)[:uid], true)
          s = State.commit_index(s, s[:commit_index] + length(entries))
          s = State.last_applied(s, s[:commit_index])
          # IO.inspect(s[:commit_log])
          IO.puts "#{inspect(Enum.at(entries, 0)[:cmd])} replicated on a majority of servers and executed by leader"
          Monitor.debug(s, "Leader has committed a new entry, leader commit_index is #{s[:commit_index]} log length #{Log.getLogSize(s[:log])}")
          send Enum.at(entries, 0)[:clientP], {:CLIENT_REPLY, %{leaderP: self()}}
          next(s)
        end
        next(s)

      {:appendEntryFailedResponse, term, false, from } ->
        # leader is out of date
        if term > s[:curr_term] do
          Monitor.debug(s, "converts to follower from leader in term #{s[:curr_term]}")
          s = State.curr_term(s, term)
          Follower.start(s)
        end

        Monitor.debug(s, "some server failed to append entry due to log inconsistency")
        # decrement next_index by 1
        new_next_index = s[:next_index][from] - 1
        s = State.next_index(s, from, new_next_index)
        new_append_entry_msg = {:appendEntry, s[:curr_term], s[:id],
                          new_next_index - 1,                      # preLogIndex
                          s[:log][new_next_index - 1][:term],      # preLogTerm
                          [s[:log][new_next_index]],
                          s[:commit_index]}
        send from, new_append_entry_msg
        next(s)

      # step down when discovered server with highter term
      {:requestVote, votePid, term, candidateId, lastLogIndex, lastLogTerm} ->
        up_to_date = lastLogTerm > Log.getPrevLogTerm(s[:log]) or
                    (lastLogTerm == Log.getPrevLogTerm(s[:log]) and lastLogIndex >= Log.getPrevLogIndex(s[:log]))

        if term > s[:curr_term] and up_to_date do
          s = State.curr_term(s, term)
          Monitor.debug(s, "converts to follower from leader in term #{s[:curr_term]}")
          # TODO: DO WE NEED TO FORWARD THIS REQUEST VOTE MSG TO THE FOLLOWER IT CONVERTS INTO?
          Follower.start(s)
        else
          send votePid, {:requestVoteResponse, s[:curr_term], false}
          next(s)
        end

      # step down when discovered server with highter term
      {:appendEntry, term, leaderId, prevLogIndex, prevLogTerm, entries, leaderCommit} ->
        if term > s[:curr_term] do
          Monitor.debug(s, "converts to follower from leader in term #{s[:curr_term]}")
          s = State.curr_term(s, term)
          # TODO: append entry response format not sure if correct, same problem in candidate, do we need this?
          send Enum.at(s[:servers], leaderId - 1), {:appendEntryFailedResponse, s[:curr_term], false, self()}
          Follower.start(s)
        end
        next(s)
    end
  end

end
