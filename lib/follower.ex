defmodule Follower do
  def start(s) do
    next(s)
  end

  defp next(s) do
    receive do
      {:appendEntry, value} ->
        next(s)
      {:requestVote, term, id} ->
        if s[:voted_for] == nil and term >= s[:curr_term] do
          send Enum.at(s[:servers], id), {:vote, term}
          s.voted_for(s, id)
        end
    end

    next(s)
  end

end
