defmodule Vote do

  def start(s) do
    # Monitor.debug(s, "Voting started!")
    # s = State.voted_for(s, self())
    # s = State.votes(s, s[:votes] + 1)

    # Note that this is a new process, so self() and selfP is different
    for server <- s[:servers], server != s[:selfP], do:
      # We added a vote pid(self) so that people know how to send the message back,
      # this is an additional attributes on top of the normal RAFT attributes.
      send server, {:requestVote, self(), s[:curr_term], s[:id], Log.getPrevLogIndex(s[:log]), Log.getPrevLogTerm(s[:log])}

    #TODO: change the time
    Process.send_after(self(), {:voteTimeOut}, (100 + DAC.random(100)))

    collectVotes(s)

    if s[:votes] < s[:majority] do
      send s[:selfP], {:NewElection, s[:curr_term]}
    end
  end

  defp collectVotes(s) do
    Monitor.debug(s, "inside collect vote!")
    receive do
      {:voteTimeOut} ->
        Monitor.debug(s, "timeout... so sad....")

      {:requestVoteResponse, term, true} ->
        s = State.votes(s, s[:votes] + 1)
        Monitor.debug(s, "collected one vote!!! The total vote is #{s[:votes]}")
        # QUESTION: SPLIT VOTE IF EVEN # OF SERVERS?
        if s[:votes] == s[:majority] do
          Monitor.debug(s, "current term: #{s[:curr_term]}, id: #{s[:id]}")
          send s[:selfP], {:Elected, s[:curr_term]}
          Process.exit(self(), :kill)
        else
          collectVotes(s)
        end
        
      {:requestVoteResponse, term, false} ->
        Monitor.debug(s, "didn't get a vote")
        collectVotes(s)
    end

  end

end
