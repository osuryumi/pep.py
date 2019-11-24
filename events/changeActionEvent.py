from common.log import logUtils as log
from constants import clientPackets
from constants import serverPackets
from objects import glob
from common.constants import actions

def handle(userToken, packetData):
	# Get usertoken data
	userID = userToken.userID
	username = userToken.username

	# Make sure we are not banned
	#if userUtils.isBanned(userID):
	#	userToken.enqueue(serverPackets.loginBanned())
	#	return

	# Send restricted message if needed
	#if userToken.restricted:
	#	userToken.checkRestricted(True)

	# Change action packet
	packetData = clientPackets.userActionChange(packetData)

	# If we are not in spectate status but we're spectating someone, stop spectating
	'''
if userToken.spectating != 0 and userToken.actionID != actions.WATCHING and userToken.actionID != actions.IDLE and userToken.actionID != actions.AFK:
	userToken.stopSpectating()

# If we are not in multiplayer but we are in a match, part match
if userToken.matchID != -1 and userToken.actionID != actions.MULTIPLAYING and userToken.actionID != actions.MULTIPLAYER and userToken.actionID != actions.AFK:
	userToken.partMatch()
		'''

	# Update cached stats if our pp changed if we've just submitted a score or we've changed gameMode
	#if (userToken.actionID == actions.PLAYING or userToken.actionID == actions.MULTIPLAYING) or (userToken.pp != userUtils.getPP(userID, userToken.gameMode)) or (userToken.gameMode != packetData["gameMode"]):

	# Update cached stats if we've changed gamemode
#will delete this
	userToken.autopilot = packetData['actionMods'] & 8192
	userToken.relax = packetData['actionMods'] & 128
	
	if packetData['actionMods'] & 128:
		userToken.enqueue(serverPackets.notification('You switched to relax!'))
		if userToken.actionID in (0, 1, 14):
			userToken.actionText = packetData["actionText"] + " on Relax"
		else:
			userToken.actionText = packetData["actionText"] + " on Relax"
			userToken.updateCachedStatsRx()
	elif packetData['actionMods'] & 8192:
		userToken.enqueue(serverPackets.notification('You switched to autopilot!'))
		if userToken.actionID in (0, 1, 14):
			userToken.actionText = packetData["actionText"] + " on Autopilot"
		else:
			userToken.actionText = packetData["actionText"] + " on Autopilot"
		userToken.updateCachedStatsAp()
	else:
		userToken.enqueue(serverPackets.notification('You switched to vanilla!'))
		userToken.actionText = packetData["actionText"]
		userToken.updateCachedStats()

	if userToken.gameMode != packetData["gameMode"]:
		userToken.gameMode = packetData["gameMode"]
		userToken.updateCachedStats()

	# Always update action id, text, md5 and beatmapID
	userToken.actionID = packetData["actionID"]
	
	userToken.actionMd5 = packetData["actionMd5"]
	userToken.actionMods = packetData["actionMods"]
	userToken.beatmapID = packetData["beatmapID"]

	# Enqueue our new user panel and stats to us and our spectators
	recipients = [userToken]
	if len(userToken.spectators) > 0:
		for i in userToken.spectators:
			if i in glob.tokens.tokens:
				recipients.append(glob.tokens.tokens[i])

	for i in recipients:
		if i is not None:
			# Force our own packet
			force = True if i == userToken else False
			i.enqueue(serverPackets.userPanel(userID, force))
			i.enqueue(serverPackets.userStats(userID, force))

	# Console output
	log.info("{} changed action: {} [{}][{}][{}]".format(username, str(userToken.actionID), userToken.actionText, userToken.actionMd5, userToken.beatmapID))
