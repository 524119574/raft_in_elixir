defmodule Leader do

  def start(s) do
    Monitor.debug(s, "I am the leader for term #{s[:curr_term]}")
    s = State.role(s, :LEADER)
    # Initialize next_index and match_index for other servers
    next_index = for server <- s[:servers], server != self(), into: %{}, do: {server, Log.getPrevLogIndex(s[:log]) + 1}
    match_index = for server <- s[:servers], server != self(), into: %{}, do: {server, 0}
    s = State.next_index(s, next_index)
    s = State.match_index(s, match_index)
    # First heartbeat to establish self as leader
    for server <- s[:servers], server != self(), do:
      send(server, {:appendEntry, s[:curr_term], s[:id], 0, 0, nil, s[:commit_index]})
    Process.send_after(self(), {:resendHeartBeat}, 20)
    next(s)
  end

  defp next(s) do
    receive do
      { :crash_timeout } -> 
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
        Monitor.notify s, {:CLIENT_REQUEST, s[:id]}
        Monitor.debug(s, "I have received a request from client in term #{s[:curr_term]}")
        # TODO: ASSUME LEN(ENTRIES) == 1
        prevLog = s[:log]
        # Add the client request to its own log.
        s = State.log(s, Enum.concat(prevLog, [%{term: s[:curr_term], uid: uid, cmd: cmd}]))
        Monitor.debug(s, "Leader log updated log length #{length(s[:log])}")
        appendEntryMsg = {:appendEntry, s[:curr_term], s[:id],
                          Log.getPrevLogIndex(prevLog),
                          Log.getPrevLogTerm(prevLog),
                          [%{term: s[:curr_term], uid: uid, cmd: cmd}],
                          s[:commit_index]}
        # Note the off by 1 error - append entry already appended to self
        s = State.append_map(s, appendEntryMsg, 1)

        # broadcast the appendEntry RPC.
        for server <- s[:servers], server != self(), do:
          send server, appendEntryMsg
        next(s)

      {:appendEntryResponse, term, success, originalMessage} ->
        # -----------
        # Monitor.debug(s, "I have received append response")
        {:appendEntry, term, leaderId, prevLogIndex,
         prevLogTerm, entries, leaderCommit} = originalMessage
        # Monitor.debug(s, "append map is: #{s[:append_map][originalMessage]}")
        s = State.append_map(s, originalMessage, s[:append_map][originalMessage] + 1)

        # TODO: update next_index and match_index

        # check if commit index condition is right
        if s[:append_map][originalMessage] >= s[:majority] and leaderCommit == s[:commit_index]  do
          # Monitor.debug(s, "COMMITED BC append map is: #{s[:append_map][originalMessage]} reaches majority")
          for entry <- entries, do:
            send s[:databaseP], {:EXECUTE, entry[:cmd]}

        # TODO: figure out client_reply format and send {:CLIENT_REPLY}

          s = State.commit_index(s, s[:commit_index] + length(entries))
          # Monitor.debug(s, "My commit index is #{s[:commit_index]}")
          Monitor.debug(s, "I have committed a new entry")
          next(s)
        end
        next(s)

      # failed append entry due to inconsistency
      {:appendEntryFailedResponse, term, false, from } ->
        Monitor.debug(s, "some server failed to append entry due to log inconsistency")
        # decrement next_index by 1
        new_next_index = s[:next_index][from] - 1
        s = State.next_index(s, from, new_next_index)
        # not sure if this lices the list correctly
        prevLog = Log.deleteLastElement(s[:log])
        new_append_entry_msg = {:appendEntry, s[:curr_term], s[:id],
                          Log.getPrevLogIndex(prevLog),
                          Log.getPrevLogTerm(prevLog),
                          Enum.at(prevLog, new_next_index - 1),
                          s[:commit_index]}
        # retries appenEntryRPC with decremented next_index
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

      {:appendEntry, term, leaderId, prevLogIndex, prevLogTerm, entries, leaderCommit} ->
        Monitor.debug(s, "converts to follower from leader in term #{s[:curr_term]}")
        if term > s[:curr_term] do
          s = State.curr_term(s, term)
          # TODO: append entry response format not sure if correct, same problem in candidate, do we need this?
          send Enum.at(s[:servers], leaderId - 1), {:appendEntryFailedResponse, s[:curr_term], false, self()}
          Follower.start(s)
        end
    end
  end

end
