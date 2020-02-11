defmodule Leader do
  # I am the leader!

  def start(s) do
    next(s)
  end

  defp next(s) do
    for server <- s[:servers], server != self(), do:
      Process.send_after server, {:appendEntry, s[:curr_term], s[:id]}, 150
    next(s)
  end

end
