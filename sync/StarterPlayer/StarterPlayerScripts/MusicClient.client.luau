--!strict
-- Conquest :: MusicClient  (every server kind)
--
-- The score plays from the moment you arrive: through the matchmaking board,
-- the teleport into a reserved server, and the whole round. Deliberately NOT
-- folded into ConquestClient -- that script yields on `awaitRole("match")`, so
-- the lobby would sit in silence, and it is busy building a map for over a
-- second at exactly the moment a player first sees the game.
--
-- CLIENT-SIDE ON PURPOSE. The Sound lives in SoundService and is replicated to
-- everyone, but a client's property writes do not replicate, so each player
-- plays their OWN copy and nobody joins halfway through somebody else's bar.
-- Played from a server Script it would be one shared playhead for the server.

local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

-- Long enough to be a swell rather than a knob being turned, short enough that
-- a player who joins straight into a round is not listening to near-silence.
local FADE_IN = 3

local music = SoundService:WaitForChild("Background Music") :: Sound

-- The volume the place was authored at. Read BEFORE the fade zeroes it, so the
-- target is whatever the Sound says it is and not a number duplicated here.
local FULL = music.Volume

-- Set on the instance as well, so the Explorer is honest on its own. Kept here
-- because a Sound that arrives unlooped simply stops after 2:28 and that
-- silence is indistinguishable from a bug.
music.Looped = true

music.Volume = 0
music:Play()
TweenService:Create(music, TweenInfo.new(FADE_IN, Enum.EasingStyle.Linear), {
	Volume = FULL,
}):Play()
