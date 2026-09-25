--!strict
-- Conquest :: Faces
--
-- THE FACE ON AN EMPIRE, for every place that draws one (the standings row, the
-- map label, the diplomacy disc). A user id is the whole contract:
--
--   > 0  a real account -- the Roblox headshot, via rbxthumb (no yield, no web
--        call of our own).
--   < 0  a CROWD identity -- a faux player with no account behind it, index
--        -uid into Faces.CROWD, drawn from its own rendered image.
--        At or below -NPC_BASE it is a plain AI nation's face instead (the
--        roster sends one; the empire itself never holds it).
--   nil  no face; the caller draws its lettered disc.
--
-- WHY NEGATIVE (2026-09-25). The Eurasia map seats sixty faux players
-- (EurasiaMap.FAUX) and only nine cleared identities have a real account --
-- the owner and the owner's `live` friends (Tutorial.FRIENDS). The rest are
-- invented usernames: fifty-six of them, fifty-one to fill and five spare for
-- a seat that is taken or a mid-round re-deal. Each was checked against
-- users.roblox.com as NOT belonging to anybody when it was written;
-- impersonating a stranger's account is the one thing this pool must never
-- do. A negative id cannot collide with an account, never lands in
-- `sim.byUserId`, and every server rule that asks `userId == nil` ("is this a
-- plain bot?") keeps reading a crowd empire as the faux it is.
--
-- `image` is a random avatar built from catalog items (R6, classic faces),
-- shot in Studio against green and blue backdrops for the cut-out and black
-- for the colour, and uploaded as an image. A row without one still works:
-- `url` returns nil and the caller falls back to the lettered disc.

local Faces = {}

Faces.CROWD = {
	{ name = "FeralKnight_73", display = "FeralKnight_73", userId = -1, image = "rbxassetid://99574095937262" },
	{ name = "moosecosmic2008", display = "moosecosmic2008", userId = -2, image = "rbxassetid://104993060771543" },
	{ name = "gamerlil2014", display = "gamerlil2014", userId = -3, image = "rbxassetid://76849281800696" },
	{ name = "SwiftBadger_71", display = "SwiftBadger_71", userId = -4, image = "rbxassetid://137303679810568" },
	{ name = "imeganinja", display = "imeganinja", userId = -5, image = "rbxassetid://130968597025610" },
	{ name = "darkgecko57", display = "darkgecko57", userId = -6, image = "rbxassetid://119975720185414" },
	{ name = "lunaraccoon946", display = "lunaraccoon946", userId = -7, image = "rbxassetid://120215971871666" },
	{ name = "liam_spicy16", display = "liam_spicy16", userId = -8, image = "rbxassetid://79248234569680" },
	{ name = "miamuffin526", display = "miamuffin526", userId = -9, image = "rbxassetid://102752869440000" },
	{ name = "icrispycomet", display = "icrispycomet", userId = -10, image = "rbxassetid://75251835629983" },
	{ name = "Sleepy_Goblin3767", display = "Sleepy_Goblin3767", userId = -11, image = "rbxassetid://103359573093262" },
	{ name = "Lil_Ghost8213", display = "Lil_Ghost8213", userId = -12, image = "rbxassetid://86776960614042" },
	{ name = "istormypanda", display = "istormypanda", userId = -13, image = "rbxassetid://124727613382362" },
	{ name = "phantomdark2012", display = "phantomdark2012", userId = -14, image = "rbxassetid://77292144836825" },
	{ name = "crispykraken26", display = "crispykraken26", userId = -15, image = "rbxassetid://94921568563655" },
	{ name = "leopickle626", display = "leopickle626", userId = -16, image = "rbxassetid://118907895996414" },
	{ name = "notsilentbean", display = "notsilentbean", userId = -17, image = "rbxassetid://120293521468305" },
	{ name = "jollyhawk25", display = "jollyhawk25", userId = -18, image = "rbxassetid://101040798190396" },
	{ name = "jollywaffle75", display = "jollywaffle75", userId = -19, image = "rbxassetid://100169586999826" },
	{ name = "ifrostyotter", display = "ifrostyotter", userId = -20, image = "rbxassetid://93816464680321" },
	{ name = "samtoast242", display = "samtoast242", userId = -21, image = "rbxassetid://136342071785178" },
	{ name = "Silent_Cookie7725", display = "Silent_Cookie7725", userId = -22, image = "rbxassetid://98695083438458" },
	{ name = "isleepyblox", display = "isleepyblox", userId = -23, image = "rbxassetid://130537463314199" },
	{ name = "walrustiny2009", display = "walrustiny2009", userId = -24, image = "rbxassetid://115299844598303" },
	{ name = "xXNobleNuggetXx", display = "xXNobleNuggetXx", userId = -25, image = "rbxassetid://89325059575646" },
	{ name = "notstormyllama", display = "notstormyllama", userId = -26, image = "rbxassetid://137926067400275" },
	{ name = "itsjollysniper2011", display = "itsjollysniper2011", userId = -27, image = "rbxassetid://119247453377042" },
	{ name = "xXStormyPigeonXx", display = "xXStormyPigeonXx", userId = -28, image = "rbxassetid://79729737059896" },
	{ name = "notmightyyeti", display = "notmightyyeti", userId = -29, image = "rbxassetid://74471758638602" },
	{ name = "finn_sneaky3", display = "finn_sneaky3", userId = -30, image = "rbxassetid://109594308457909" },
	{ name = "ethan_mighty4", display = "ethan_mighty4", userId = -31, image = "rbxassetid://71482548871883" },
	{ name = "sam_tiny46", display = "sam_tiny46", userId = -32, image = "rbxassetid://119977362466908" },
	{ name = "notstormynoodle", display = "notstormynoodle", userId = -33, image = "rbxassetid://90308202130501" },
	{ name = "Lucky_Viper6572", display = "Lucky_Viper6572", userId = -34, image = "rbxassetid://93618261861908" },
	{ name = "noah_blazing72", display = "noah_blazing72", userId = -35, image = "rbxassetid://87189090119241" },
	{ name = "ivy_frosty66", display = "ivy_frosty66", userId = -36, image = "rbxassetid://114200049359470" },
	{ name = "itswildmoose2011", display = "itswildmoose2011", userId = -37, image = "rbxassetid://107308539864067" },
	{ name = "wobblyfox85", display = "wobblyfox85", userId = -38, image = "rbxassetid://102378405143359" },
	{ name = "TinyHawk_61", display = "TinyHawk_61", userId = -39, image = "rbxassetid://134180150620766" },
	{ name = "ellacomet500", display = "ellacomet500", userId = -40, image = "rbxassetid://113826360904519" },
	{ name = "isleepyviper", display = "isleepyviper", userId = -41, image = "rbxassetid://122496269193325" },
	{ name = "xXStormyKrakenXx", display = "xXStormyKrakenXx", userId = -42, image = "rbxassetid://86713198340863" },
	{ name = "knightgrumpy2009", display = "knightgrumpy2009", userId = -43, image = "rbxassetid://70872070209761" },
	{ name = "xXNobleWaffleXx", display = "xXNobleWaffleXx", userId = -44, image = "rbxassetid://129979709978380" },
	{ name = "Sly_Blox7179", display = "Sly_Blox7179", userId = -45, image = "rbxassetid://74446425371557" },
	{ name = "notsleepyknight", display = "notsleepyknight", userId = -46, image = "rbxassetid://70965321762484" },
	{ name = "xXFuzzyHawkXx", display = "xXFuzzyHawkXx", userId = -47, image = "rbxassetid://127071797085011" },
	{ name = "rustykraken99", display = "rustykraken99", userId = -48, image = "rbxassetid://97736652623184" },
	{ name = "xXChillOtterXx", display = "xXChillOtterXx", userId = -49, image = "rbxassetid://89729114803533" },
	{ name = "FeralNinja_36", display = "FeralNinja_36", userId = -50, image = "rbxassetid://80113593153779" },
	{ name = "kai_grumpy19", display = "kai_grumpy19", userId = -51, image = "rbxassetid://119108293178825" },
	{ name = "zoecactus318", display = "zoecactus318", userId = -52, image = "rbxassetid://122461730629185" },
	{ name = "owenwalrus77", display = "owenwalrus77", userId = -53, image = "rbxassetid://88263152798356" },
	{ name = "rubymoose_42", display = "rubymoose_42", userId = -54, image = "rbxassetid://129063891784332" },
	{ name = "notclumsyyeti", display = "notclumsyyeti", userId = -55, image = "rbxassetid://136997781998350" },
	{ name = "ivykraken205", display = "ivykraken205", userId = -56, image = "rbxassetid://110270177619354" },
} :: { { name: string, display: string, userId: number, image: string? } }

-- THE NPC NATIONS' FACES (owner, 2026-09-25: "i want npcs to have pfps too.
-- just generate random ass pfp characters"). Rendered the same way as the
-- crowd's, from the same catalog, and dealt by empire id: ConquestServer's
-- roster sends a plain AI nation's `u` as -(NPC_BASE + empire id), so the
-- face sticks to one nation for the whole round. NEVER stored on the empire
-- (`p.userId` stays nil) -- every server rule that asks "is this a plain bot?"
-- reads that field.
Faces.NPC_BASE = 1000
Faces.NPC = {
	"rbxassetid://112115192677657",
	"rbxassetid://137100153423845",
	"rbxassetid://111530720284289",
	"rbxassetid://135419727660552",
	"rbxassetid://87743589170979",
	"rbxassetid://80335414410362",
	"rbxassetid://118666929136329",
	"rbxassetid://116945106940649",
	"rbxassetid://73885599156691",
	"rbxassetid://102091285366524",
	"rbxassetid://101904474806845",
	"rbxassetid://79332264756727",
	"rbxassetid://109222412241290",
	"rbxassetid://133605136029412",
	"rbxassetid://129839937457992",
	"rbxassetid://125636784617990",
	"rbxassetid://75837214554948",
	"rbxassetid://74281365088218",
	"rbxassetid://94767583256820",
	"rbxassetid://136351991706022",
	"rbxassetid://85169943213032",
	"rbxassetid://95758147988422",
	"rbxassetid://92572546479775",
	"rbxassetid://124572924781660",
	"rbxassetid://76384508874475",
	"rbxassetid://116868869352204",
	"rbxassetid://98432341602918",
	"rbxassetid://80989134069968",
	"rbxassetid://74027246710871",
	"rbxassetid://139860719445629",
	"rbxassetid://136886572864380",
	"rbxassetid://108342853734933",
	"rbxassetid://71218548803596",
	"rbxassetid://116286917133641",
	"rbxassetid://75616147168415",
	"rbxassetid://120788731032617",
	"rbxassetid://85051854854662",
	"rbxassetid://127052055170216",
	"rbxassetid://125816991824004",
	"rbxassetid://93911190807731",
	"rbxassetid://122827364940002",
	"rbxassetid://73602161758305",
	"rbxassetid://79435624355213",
	"rbxassetid://91607434792025",
	"rbxassetid://115078933916082",
	"rbxassetid://131901008581856",
	"rbxassetid://123100781603864",
	"rbxassetid://138952267923135",
	"rbxassetid://119719827122936",
	"rbxassetid://136940927908342",
	"rbxassetid://91639369422360",
	"rbxassetid://80341639958361",
	"rbxassetid://71536273677565",
	"rbxassetid://110480883021378",
	"rbxassetid://100802570718538",
	"rbxassetid://73928647541522",
	"rbxassetid://70498364433049",
	"rbxassetid://125863681714990",
	"rbxassetid://121144577699917",
	"rbxassetid://101062344593143",
	"rbxassetid://90532497048631",
	"rbxassetid://92377875872339",
	"rbxassetid://110174640218807",
	"rbxassetid://138871493822506",
} :: { string }

function Faces.url(userId: number?, size: number?): string?
	if userId == nil or userId == 0 then
		return nil
	end
	if userId > 0 then
		local s = size or 150
		return string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=%d&h=%d", userId, s, s)
	end
	if -userId >= Faces.NPC_BASE then
		return Faces.NPC[(-userId - Faces.NPC_BASE) % #Faces.NPC + 1]
	end
	local row = Faces.CROWD[-userId]
	return row and row.image or nil
end

return Faces
