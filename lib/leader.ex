defmodule Leader do

  def start(s) do
    Monitor.debug(s, "I am the leader for term #{s[:curr_term]}")
    s = State.role(s, :LEADER)
    for server <- s[:servers], server != self(), do:
      send(server, {:appendEntry, s[:curr_term], s[:id], 0})
    Process.send_after(self(), {:resendHeartBeat}, 50)
    next(s)
  end

  defp next(s) do
    receive do
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
        Monitor.debug(s, "I have received a request from client in term #{s[:curr_term]}")
        prevLog = s[:log]
        # Add the client request to its own log.
        s = State.log(s, Enum.concat(prevLog, [%{term: s[:curr_term], uid: uid, cmd: cmd}]))
        appendEntryMsg = {:appendEntry, s[:curr_term], s[:id],
                          Log.getPrevLogIndex(prevLog),
                          Log.getPrevLogTerm(prevLog),
                          [cmd],
                          s[:commit_index]}
        # broadcast the appendEntry RPC.
        for server <- s[:servers], server != self(), do:
          send server, appendEntryMsg
        s = State.append_map(s, appendEntryMsg, 0)
        # Monitor.debug(s, "appendentry message is: #{appendEntryMsg}")
        Monitor.debug(s, "map is: #{s[:append_map][appendEntryMsg]}")
        next(s)
      {:appendEntryResponse, term, res, originalMessage} ->
        # -----------
        Monitor.debug(s, "I have received append response")
        {:appendEntry, term, leaderId, prevLogIndex,
         prevLogTerm, entries, leaderCommit} = originalMessage
        Monitor.debug(s, "map is: #{s[:append_map][originalMessage]}")
        s = State.append_map(s, originalMessage, s[:append_map][originalMessage] + 1)
        if s[:append_map][originalMessage] >= s[:majority] and leaderCommit == s[:commit_index]  do
          for entry <- entries, do:
            send s[:databaseP], {:EXECUTE, entry}
          s = State.commit_index(s, s[:commit_index] + length(entries))
          Monitor.debug(s, "My commit index is #{s[:commit_index]}")
          Monitor.debug(s, "I have committed a new entry")
          next(s)
        end
        next(s)

      # TODO: step down when discovered server with highter term
      # {:requestVote, votePid, term, candidateId, lastLogIndex, lastLogTerm} when term > s[:curr_term] ->
      #   # need to reset voted_for and vote counts or not?
      #   Follower.start(s)

      # {:appendEntry, term, leaderId, prevLogIndex} when term > s[:curr_term] ->
      #   s = State.voted_for(s, nil)
      #   s = State.curr_term(s, term)
      #   s = State.votes(0)
      #   Follower.start(s)
    end
  end

end
