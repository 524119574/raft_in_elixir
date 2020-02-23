defmodule Leader do

  def start(s) do
    Monitor.debug(s, 4, "I am the leader for term #{s[:curr_term]} with log length #{Log.getLogSize(s[:log])}")
    s = State.role(s, :LEADER)
    s = State.leader_id(s, s[:id])

    # Initialize next_index and match_index for other servers
    next_index = for server <- s[:servers], server != self(), into: %{}, do: {server, s[:commit_index] + 1}
    match_index = for server <- s[:servers], server != self(), into: %{}, do: {server, 0}
    s = State.next_index(s, next_index)
    s = State.match_index(s, match_index)

    # First heartbeat to establish self as leader
    for server <- s[:servers], server != self() do
      send(server, {:appendEntry, s[:curr_term], s[:id],
                    Log.getPrevLogIndex(s[:log]), Log.getPrevLogTerm(s[:log]), nil, s[:commit_index]})
    end

    Process.send_after(self(), {:resendHeartBeat}, 50)

    # leader crash every 3000 ms
    Process.send_after(self(), {:crash_and_restart}, 3000)

    next(s)
  end

  defp next(s) do

    receive do
      {:crash_timeout} ->

        Monitor.debug(s, 4, "leader crashed and will NOT restart with log length #{Log.getLogSize(s[:log])}")
        Process.sleep(30_000)

      {:crash_and_restart} ->

        Monitor.debug(s, 4, "leader crashed and will sleep for 800 ms")
        Process.sleep(800)
        Monitor.debug(s, 4, "leader finished sleeping and restarted with log length #{Log.getLogSize(s[:log])}")
        next(s)

      {:resendHeartBeat} ->

        for {follower, next_index} <- s[:next_index] do
          entries = if Log.getPrevLogIndex(s[:log]) >= next_index
                    do Log.getEntriesStartingFrom(s[:log], next_index)
                    else nil end
          send(follower, {:appendEntry, s[:curr_term], s[:id],
                          Log.getPrevLogIndex(s[:log]),   # prevLogIndex
                          Log.getPrevLogTerm(s[:log]),   # prevLogTerm
                          entries, # entries
                          s[:commit_index]})
        end
        Process.send_after(self(), {:resendHeartBeat}, 50)
        next(s)

      {:CLIENT_REQUEST, %{clientP: client, uid: uid, cmd: cmd}} ->

        Monitor.notify(s, { :CLIENT_REQUEST, s[:id] })
        Monitor.debug(s, 2, "Leader received a request from client in term #{s[:curr_term]} cmd is #{inspect(cmd)} uid is #{inspect(uid)}")
        prevLog = s[:log]
        newLogEntry = %{term: s[:curr_term], uid: uid, cmd: cmd, clientP: client}
        # Add the client request to its own log.
        s = State.log(s, Log.appendNewEntry(prevLog,newLogEntry))

        # Monitor.debug(s, 2, "Leader log updated log length #{Log.getLogSize(s[:log])}")
        appendEntryMsg = {:appendEntry, s[:curr_term], s[:id],
                          Log.getPrevLogIndex(prevLog),
                          Log.getPrevLogTerm(prevLog),
                          [newLogEntry],
                          s[:commit_index]}

        # broadcast the appendEntry RPC.
        for server <- s[:servers], server != self() do
          send server, appendEntryMsg
        end
        next(s)

      {:appendEntryResponse, term, true, from, matchIndex} ->

        if term > s[:curr_term] do
          Monitor.debug(s, 4, "converts to follower from leader with log length #{Log.getLogSize(s[:log])}")
          s = State.curr_term(s, term)
          Follower.start(s)
        end

        # update match_index and next_index
        s = State.next_index(s, from, max(matchIndex + 1, s[:next_index][from]))
        s = State.match_index(s, from, max(matchIndex, s[:match_index][from]))

        s = update_commit_index(s, from)

        s = commit_entries_and_notify_clients(s)

        # Notify all followers that the commit index has been updated.
        for server <- s[:servers], server != self(), do:
          send(server, {:appendEntry, s[:curr_term], s[:id],
                        Log.getPrevLogIndex(s[:log]), Log.getPrevLogTerm(s[:log]),
                        nil, s[:commit_index]})

        next(s)

      {:appendEntryResponse, term, false, from } ->
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
                                new_next_index - 1,                  # preLogIndex
                                s[:log][new_next_index - 1][:term],  # preLogTerm
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
          send Enum.at(s[:servers], leaderId - 1), {:appendEntryResponse, s[:curr_term], false, self(), s[:last_applied]}
          Follower.start(s)
        end
        next(s)
    end
  end

  defp update_commit_index(s, from) do
    match_indexes = s[:match_index] |> Enum.map(fn {_, v} -> v end)
    # Get all the possible commit index and its corresponding count.
    newCommitIndex_match_list =
      for newCommitIndex <- s[:commit_index]..s[:match_index][from] do
        {newCommitIndex, Enum.count(match_indexes, fn i -> i >= newCommitIndex end)}
      end
    # Get all the possible commit index that satisfies the condition.
    candidateCommitIndexes = Enum.filter(
      newCommitIndex_match_list,
      # since the count doesn't include itself so we minus 1 here.
      fn {i, c} -> (i > s[:commit_index] and c >= s[:majority] - 1 and s[:log][i][:term] == s[:curr_term]) end)
    # Monitor.debug s, "new commit index list #{inspect(candidateCommitIndexes)}"
    State.commit_index(s, if (length(candidateCommitIndexes) > 0)
                          do elem(Enum.at(candidateCommitIndexes, -1), 0)
                          else s[:commit_index] end)
  end

  defp commit_entries_and_notify_clients(s) do
    if s[:commit_index] > s[:last_applied] do
      num_to_execute = s[:commit_index] - s[:last_applied]
      Monitor.debug(s, "committing: #{inspect(Log.getEntriesBetween(s[:log], s[:last_applied] + 1, s[:commit_index]))}")
      for i <- 1..num_to_execute do
        log_index = s[:last_applied] + i
        send s[:databaseP], {:EXECUTE, s[:log][log_index][:cmd]}
        send s[:log][log_index][:clientP], {:CLIENT_REPLY, %{leaderP: self()}}
      end
      # s = Enum.reduce(1..num_to_execute, s, fn i, s -> State.commit_log(s, s[:log][s[:last_applied] + i][:uid], true) end)
      State.last_applied(s, s[:commit_index])
    else
      s
    end
  end

end
