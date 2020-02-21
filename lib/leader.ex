defmodule Leader do

  def start(s) do
    Monitor.debug(s, 4, "I am the leader for term #{s[:curr_term]} with log length #{Log.getLogSize(s[:log])}")
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

    # leader crash every 2000 ms
    Process.send_after(self(), {:crash_timeout}, 5000)

    # commit uncommitted index in its log
    if Log.getLogSize(s[:log]) > s[:commit_index] do
      Monitor.debug(s, 4, "Leader encounters previously uncommitted entry")
      num_of_entries = Log.getLogSize(s[:log]) - s[:commit_index]
      append_msgs = Enum.map(1..num_of_entries, fn i ->
        {:appendEntry, s[:curr_term], s[:id],
                      Log.getPrevLogIndex(s[:log]) - i,                  #prevLogIndex
                      s[:log][Log.getPrevLogIndex(s[:log]) - i][:term],  #prevLogTerm
                      [s[:log][Log.getPrevLogIndex(s[:log]) + 1 - i]],
                      s[:commit_index]} end)
      # reverse msgs to send in log entry order
      append_msgs = Enum.reverse(append_msgs)

      # broadcast appendEntry
      Enum.map(append_msgs, fn msg ->
        for server <- s[:servers], server != self(), do:
          send server, msg
        end)
      # put messages into append_map
      s = Enum.reduce(append_msgs, s, fn msg, s -> State.append_map(s, msg, 1) end)
      IO.inspect(s[:append_map])
      Monitor.debug(s, 4, "leader sends uncommitted log entry to followers")
      next(s)
    end
    next(s)
  end

  defp next(s) do

    receive do
      { :crash_timeout } ->
        Monitor.debug(s, 4, "crashed and will sleep for 1000 ms")
        Process.sleep(1000)
        Monitor.debug(s, 4, "leader finished sleeping and restarted with log length #{Log.getLogSize(s[:log])}")
        next(s)
        # Monitor.debug(s, 4, "crashed and will NOT restart with log length #{Log.getLogSize(s[:log])}")
        # Process.sleep(30_000)

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
        # prevents broadcasting the same request twice (client sends repetitively cuz timeout)
        if (!Map.has_key?(s[:commit_log], uid)) do
          Monitor.notify(s, { :CLIENT_REQUEST, s[:id] })
          # Monitor.debug(s, 2, "Leader received a request from client in term #{s[:curr_term]} cmd is #{inspect(cmd)} uid is #{inspect(uid)}")
          prevLog = s[:log]
          # Add the client request to its own log.
          s = State.log(s, Log.appendNewEntry(prevLog, %{term: s[:curr_term], uid: uid, cmd: cmd, clientP: client}))
          s = State.commit_log(s, uid, false)
          # Monitor.debug(s, 2, "Leader log updated log length #{Log.getLogSize(s[:log])}")
          appendEntryMsg = {:appendEntry, s[:curr_term], s[:id],
                            Log.getPrevLogIndex(prevLog),
                            Log.getPrevLogTerm(prevLog),
                            [%{term: s[:curr_term], uid: uid, cmd: cmd, clientP: client}],
                            s[:commit_index]}
          # Note the off by 1 error - append entry already appended to self
          # s = State.append_map(s, appendEntryMsg, 1)

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

        # update match_index and next_index
        s = State.next_index(s, from, max(matchIndex + 1, s[:next_index][from]))
        s = State.match_index(s, from, max(matchIndex, s[:match_index][from]))

        # induction step if follower's log does not exactly match leader's yet
        if matchIndex < s[:commit_index] and s[:next_index][from] <= Log.getLogSize(s[:log]) do
          send from, {:appendEntry, s[:curr_term], s[:id],
                            s[:next_index][from] - 1,                   #prevLogIndex
                            s[:log][s[:next_index][from] - 1][:term],   #prevLogTerm
                            [s[:log][s[:next_index][from]]],
                            s[:commit_index]}
        end

        # MIGHT RAISE ARITHMATIC ERROR
        # Monitor.debug(s, 2, "append map is: #{inspect(s[:append_map])}")
        # Monitor.debug(s, 2, "original message: #{inspect(originalMessage)}")
        s = State.append_map(s, originalMessage, Map.get(s[:append_map], originalMessage, 1) + 1)
        # s = State.append_map(s, originalMessage, s[:append_map][originalMessage] + 1)

        # check if commit index condition is right
        if s[:append_map][originalMessage] == s[:majority] and leaderCommit <= s[:commit_index]
        and Enum.at(entries, 0) != nil and entries != nil and prevLogIndex + 1 > s[:last_applied] do
        # and !s[:commit_log][Enum.at(entries, 0)[:uid]] and entries != nil do
          for entry <- entries, do: send s[:databaseP], {:EXECUTE, entry[:cmd]}
          s = State.commit_log(s, Enum.at(entries, 0)[:uid], true)
          s = State.commit_index(s, s[:commit_index] + length(entries))
          s = State.last_applied(s, s[:commit_index])
          # IO.inspect(s[:commit_log])
          # Monitor.debug(s, 2, "#{inspect(Enum.at(entries, 0)[:cmd])} replicated on a majority of servers and executed, leader commit_index is #{s[:commit_index]} log length #{Log.getLogSize(s[:log])}")
          send Enum.at(entries, 0)[:clientP], {:CLIENT_REPLY, %{leaderP: self()}}
          next(s)
        end
        next(s)

      {:appendEntryFailedResponse, term, false, from } ->
        # leader is out of date
        if term > s[:curr_term] do
          Monitor.debug(s, 4, "converts to follower from leader with log length #{Log.getLogSize(s[:log])}")
          s = State.curr_term(s, term)
          Follower.start(s)
        end

        # Monitor.debug(s, 2, "some follower server failed to append entry due to log inconsistency")
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
          Monitor.debug(s, 4, "converts to follower from leader with log length #{Log.getLogSize(s[:log])}")
          Follower.start(s)
        end
        send votePid, {:requestVoteResponse, s[:curr_term], false}
        next(s)

      # step down when discovered server with highter term
      {:appendEntry, term, leaderId, prevLogIndex, prevLogTerm, entries, leaderCommit} ->
        if term > s[:curr_term] do
          Monitor.debug(s, 4, "converts to follower from leader in term #{s[:curr_term]} with log length #{Log.getLogSize(s[:log])}")
          s = State.curr_term(s, term)
          send Enum.at(s[:servers], leaderId - 1), {:appendEntryFailedResponse, s[:curr_term], false, self()}
          Follower.start(s)
        end
        next(s)
    end
  end

end
