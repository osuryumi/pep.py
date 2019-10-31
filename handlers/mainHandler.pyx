import datetime
import gzip
import sys
import traceback

import tornado.gen
import tornado.web
from raven.contrib.tornado import SentryMixin

from common.log import logUtils as log
from common.web import requestsManager
from constants import exceptions
from constants import packetIDs
from constants import serverPackets
from events import cantSpectateEvent
from events import changeActionEvent
from events import changeMatchModsEvent
from events import changeMatchPasswordEvent
from events import changeMatchSettingsEvent
from events import changeSlotEvent
from events import channelJoinEvent
from events import channelPartEvent
from events import createMatchEvent
from events import friendAddEvent
from events import friendRemoveEvent
from events import joinLobbyEvent
from events import joinMatchEvent
from events import loginEvent
from events import logoutEvent
from events import matchChangeTeamEvent
from events import matchCompleteEvent
from events import matchFailedEvent
from events import matchFramesEvent
from events import matchHasBeatmapEvent
from events import matchInviteEvent
from events import matchLockEvent
from events import matchNoBeatmapEvent
from events import matchPlayerLoadEvent
from events import matchReadyEvent
from events import matchSkipEvent
from events import matchStartEvent
from events import matchTransferHostEvent
from events import partLobbyEvent
from events import partMatchEvent
from events import requestStatusUpdateEvent
from events import sendPrivateMessageEvent
from events import sendPublicMessageEvent
from events import setAwayMessageEvent
from events import spectateFramesEvent
from events import startSpectatingEvent
from events import stopSpectatingEvent
from events import userPanelRequestEvent
from events import userStatsRequestEvent
from events import tournamentMatchInfoRequestEvent
from events import tournamentJoinMatchChannelEvent
from events import tournamentLeaveMatchChannelEvent
from helpers import packetHelper
from objects import glob
from common.sentry import sentry


class handler(requestsManager.asyncRequestHandler):
	@tornado.web.asynchronous
	@tornado.gen.engine
	@sentry.captureTornado
	def asyncPost(self):
		# Track time if needed
		if glob.outputRequestTime:
			# Start time
			st = datetime.datetime.now()

		# Client's token string and request data
		requestTokenString = self.request.headers.get("osu-token")
		requestData = self.request.body

		# Server's token string and request data
		responseTokenString = "ayy"
		responseData = bytes()

		if requestTokenString is None:
			# No token, first request. Handle login.
			responseTokenString, responseData = loginEvent.handle(self)
		else:
			userToken = None	# default value
			try:
				# This is not the first packet, send response based on client's request
				# Packet start position, used to read stacked packets
				pos = 0

				# Make sure the token exists
				if requestTokenString not in glob.tokens.tokens:
					raise exceptions.tokenNotFoundException()

				# Token exists, get its object and lock it
				userToken = glob.tokens.tokens[requestTokenString]
				userToken.processingLock.acquire()

				# Keep reading packets until everything has been read
				while pos < len(requestData):
					# Get packet from stack starting from new packet
					leftData = requestData[pos:]

					# Get packet ID, data length and data
					packetID = packetHelper.readPacketID(leftData)
					dataLength = packetHelper.readPacketLength(leftData)
					packetData = requestData[pos:(pos+dataLength+7)]

					# Console output if needed
					if glob.outputPackets and packetID != 4:
						log.debug("Incoming packet ({})({}):\n\nPacket code: {}\nPacket length: {}\nSingle packet data: {}\n".format(requestTokenString, userToken.username, str(packetID), str(dataLength), str(packetData)))

					# Event handler
					def handleEvent(ev):
						def wrapper():
							ev.handle(userToken, packetData)
						return wrapper

					eventHandler = {
						packetIDs.client_changeAction: handleEvent(changeActionEvent),
						packetIDs.client_logout: handleEvent(logoutEvent),
						packetIDs.client_friendAdd: handleEvent(friendAddEvent),
						packetIDs.client_friendRemove: handleEvent(friendRemoveEvent),
						packetIDs.client_userStatsRequest: handleEvent(userStatsRequestEvent),
						packetIDs.client_requestStatusUpdate: handleEvent(requestStatusUpdateEvent),
						packetIDs.client_userPanelRequest: handleEvent(userPanelRequestEvent),

						packetIDs.client_channelJoin: handleEvent(channelJoinEvent),
						packetIDs.client_channelPart: handleEvent(channelPartEvent),
						packetIDs.client_sendPublicMessage: handleEvent(sendPublicMessageEvent),
						packetIDs.client_sendPrivateMessage: handleEvent(sendPrivateMessageEvent),
						packetIDs.client_setAwayMessage: handleEvent(setAwayMessageEvent),

						packetIDs.client_startSpectating: handleEvent(startSpectatingEvent),
						packetIDs.client_stopSpectating: handleEvent(stopSpectatingEvent),
						packetIDs.client_cantSpectate: handleEvent(cantSpectateEvent),
						packetIDs.client_spectateFrames: handleEvent(spectateFramesEvent),

						packetIDs.client_joinLobby: handleEvent(joinLobbyEvent),
						packetIDs.client_partLobby: handleEvent(partLobbyEvent),
						packetIDs.client_createMatch: handleEvent(createMatchEvent),
						packetIDs.client_joinMatch: handleEvent(joinMatchEvent),
						packetIDs.client_partMatch: handleEvent(partMatchEvent),
						packetIDs.client_matchChangeSlot: handleEvent(changeSlotEvent),
						packetIDs.client_matchChangeSettings: handleEvent(changeMatchSettingsEvent),
						packetIDs.client_matchChangePassword: handleEvent(changeMatchPasswordEvent),
						packetIDs.client_matchChangeMods: handleEvent(changeMatchModsEvent),
						packetIDs.client_matchReady: handleEvent(matchReadyEvent),
						packetIDs.client_matchNotReady: handleEvent(matchReadyEvent),
						packetIDs.client_matchLock: handleEvent(matchLockEvent),
						packetIDs.client_matchStart: handleEvent(matchStartEvent),
						packetIDs.client_matchLoadComplete: handleEvent(matchPlayerLoadEvent),
						packetIDs.client_matchSkipRequest: handleEvent(matchSkipEvent),
						packetIDs.client_matchScoreUpdate: handleEvent(matchFramesEvent),
						packetIDs.client_matchComplete: handleEvent(matchCompleteEvent),
						packetIDs.client_matchNoBeatmap: handleEvent(matchNoBeatmapEvent),
						packetIDs.client_matchHasBeatmap: handleEvent(matchHasBeatmapEvent),
						packetIDs.client_matchTransferHost: handleEvent(matchTransferHostEvent),
						packetIDs.client_matchFailed: handleEvent(matchFailedEvent),
						packetIDs.client_matchChangeTeam: handleEvent(matchChangeTeamEvent),
						packetIDs.client_invite: handleEvent(matchInviteEvent),

						packetIDs.client_tournamentMatchInfoRequest: handleEvent(tournamentMatchInfoRequestEvent),
						packetIDs.client_tournamentJoinMatchChannel: handleEvent(tournamentJoinMatchChannelEvent),
						packetIDs.client_tournamentLeaveMatchChannel: handleEvent(tournamentLeaveMatchChannelEvent),
					}

					# Packets processed if in restricted mode.
					# All other packets will be ignored if the user is in restricted mode
					packetsRestricted = [
						packetIDs.client_logout,
						packetIDs.client_userStatsRequest,
						packetIDs.client_requestStatusUpdate,
						packetIDs.client_userPanelRequest,
						packetIDs.client_changeAction,
						packetIDs.client_channelJoin,
						packetIDs.client_channelPart,
					]

					# Process/ignore packet
					if packetID != 4:
						if packetID in eventHandler:
							if not userToken.restricted or (userToken.restricted and packetID in packetsRestricted):
								eventHandler[packetID]()
							else:
								log.warning("Ignored packet id from {} ({}) (user is restricted)".format(requestTokenString, packetID))
						else:
							log.warning("Unknown packet id from {} ({})".format(requestTokenString, packetID))

					# Update pos so we can read the next stacked packet
					# +7 because we add packet ID bytes, unused byte and data length bytes
					pos += dataLength+7

				# Token queue built, send it
				responseTokenString = userToken.token
				responseData = userToken.queue
				userToken.resetQueue()
			except exceptions.tokenNotFoundException:
				# Token not found. Disconnect that user
				responseData = serverPackets.loginError()
				responseData += serverPackets.notification("Whoops! Something went wrong, please login again.")
				log.warning("Received packet from unknown token ({}).".format(requestTokenString))
				log.info("{} has been disconnected (invalid token)".format(requestTokenString))
			finally:
				# Unlock token
				if userToken is not None:
					# Update ping time for timeout
					userToken.updatePingTime()
					# Release processing lock
					userToken.processingLock.release()
					# Delete token if kicked
					if userToken.kicked:
						glob.tokens.deleteToken(userToken)

		if glob.outputRequestTime:
			# End time
			et = datetime.datetime.now()

			# Total time:
			tt = float((et.microsecond-st.microsecond)/1000)
			log.debug("Request time: {}ms".format(tt))

		# Send server's response to client
		# We don't use token object because we might not have a token (failed login)
		if glob.gzip:
			# First, write the gzipped response
			self.write(gzip.compress(responseData, int(glob.conf.config["server"]["gziplevel"])))

			# Then, add gzip headers
			self.add_header("Vary", "Accept-Encoding")
			self.add_header("Content-Encoding", "gzip")
		else:
			# First, write the response
			self.write(responseData)

		# Add all the headers AFTER the response has been written
		self.set_status(200)
		self.add_header("cho-token", responseTokenString)
		self.add_header("cho-protocol", "19")
		self.add_header("Connection", "keep-alive")
		self.add_header("Keep-Alive", "timeout=5, max=100")
		self.add_header("Content-Type", "text/html; charset=UTF-8")

	@tornado.web.asynchronous
	@tornado.gen.engine
	def asyncGet(self):
		html = """
		<!DOCTYPE html>
<html lang="en" >
<head>
  <meta charset="UTF-8">
  <title>What are you doing here?</title>
  <style type="text/css">
  	html, body {
  height: 100%;
}

body {
  font-family: Helvetica, sans-serif;
  overflow: hidden;
  margin: 0;
}

.bg {
  position: absolute;
  top: 0;
  left: 0;
  width: 100%;
  height: 100%;
  background: url(https://i.ytimg.com/vi/SmQCpW72jDY/maxresdefault.jpg);
  background-size: cover;
  transform: scale(1.1);
}

.menu {
  text-align: center;
  display: flex;
  flex-direction: row;
  justify-content: flex-start;
  align-items: center;
  position: absolute;
  top: 50%;
  left: 0;
  margin-top: -100px;
  margin-left: 300px;
}
.menu .brand {
  position: relative;
  width: 200px;
  height: 200px;
  background-color: #ff66aa;
  border-radius: 100%;
  display: flex;
  flex-direction: row;
  justify-content: center;
  align-items: center;
  color: #fff;
  font-size: 64px;
  font-weight: bold;
  animation: beat 0.3529411765s;
  animation-iteration-count: infinite;
  margin: 0 -50px;
  z-index: 100;
  border: 8px solid #fff;
  box-shadow: 2px 0 4px rgba(0, 0, 0, 0.2);
  overflow: hidden;
}
.menu .brand canvas {
  position: absolute;
  top: 0;
  left: 0;
  width: 100%;
  height: 100%;
  mix-blend-mode: overlay;
}
.menu .brand span {
  position: relative;
  z-index: 1;
}
.menu .brand ~ .button:not(:first-of-type) {
  margin-left: -30px;
}
.menu .button {
  position: relative;
  background: none;
  border: none;
  display: inline-flex;
  flex-direction: column;
  justify-content: center;
  align-items: center;
  text-decoration: none;
  width: 200px;
  height: 100px;
  animation: un-hover 0.25s ease-in-out;
  animation-fill-mode: forwards;
}
.menu .button:nth-of-type(1) {
  z-index: 23;
}
.menu .button:nth-of-type(2) {
  z-index: 22;
}
.menu .button:nth-of-type(3) {
  z-index: 21;
}
.menu .button:nth-of-type(4) {
  z-index: 20;
}
.menu .button:nth-of-type(5) {
  z-index: 19;
}
.menu .button:nth-of-type(6) {
  z-index: 18;
}
.menu .button:nth-of-type(7) {
  z-index: 17;
}
.menu .button:nth-of-type(8) {
  z-index: 16;
}
.menu .button:nth-of-type(9) {
  z-index: 15;
}
.menu .button:nth-of-type(10) {
  z-index: 14;
}
.menu .button:nth-of-type(11) {
  z-index: 13;
}
.menu .button:nth-of-type(12) {
  z-index: 12;
}
.menu .button:nth-of-type(13) {
  z-index: 11;
}
.menu .button:nth-of-type(14) {
  z-index: 10;
}
.menu .button:nth-of-type(15) {
  z-index: 9;
}
.menu .button:nth-of-type(16) {
  z-index: 8;
}
.menu .button:nth-of-type(17) {
  z-index: 7;
}
.menu .button:nth-of-type(18) {
  z-index: 6;
}
.menu .button:nth-of-type(19) {
  z-index: 5;
}
.menu .button:nth-of-type(20) {
  z-index: 4;
}
.menu .button span {
  position: relative;
  z-index: 1;
  font-size: 14px;
  color: #fff;
  text-shadow: 0 4px 4px rgba(0, 0, 0, 0.2);
}
.menu .button:before {
  content: '';
  position: absolute;
  top: 0;
  left: 0;
  width: 100%;
  height: 100%;
  transform: skew(-10deg);
  box-shadow: 2px 0 4px rgba(0, 0, 0, 0.2);
}
.menu .button:hover {
  animation: hover 0.25s ease-in-out;
  animation-fill-mode: forwards;
  margin-left: 0 !important;
}
.menu .button.button--green:before {
  background-color: #6fa;
}
.menu .button.button--aqua:before {
  background: #5af;
}
.menu .button.button--pink:before {
  background: #f4427a;
}
.menu .button.button--purple:before {
  background: #C400AB;
}

@keyframes beat {
  from {
    transform: scale(0.96);
  }
}
@keyframes hover {
  from {
    width: 250px;
  }
  20% {
    width: 220px;
  }
  40% {
    width: 240px;
  }
  80% {
    width: 235px;
  }
  100% {
    width: 238px;
  }
}
@keyframes un-hover {
  from {
    width: 180px;
  }
  20% {
    width: 220px;
  }
  40% {
    width: 190px;
  }
  80% {
    width: 205px;
  }
  100% {
    width: 200px;
  }
}
  </style>

</head>
<body>
<!-- partial:index.partial.html -->
<div class="bg"></div>
<div class="menu">
   <div class="brand">
      <canvas id="triangles" width="200" height="200"></canvas>
      <span>osu!</span>
   </div>
  <a target="_blank" href="https://minase.tk" class="button button--pink">
      <span>
         Play
      </span>
   </a>
  <a target="_blank" href="https://old.minase.tk" class="button button--aqua">
      <span>
         Old site
      </span>
   </a>
   
   <a target="_blank" href="https://vk.com/kotypey_vzloman" class="button button--purple">
      <span>
         VK
      </span>
   </a>
   <a target="_blank" href="https://discord.gg/zPPDwcc" class="button button--green">
      <span>
         Discord
      </span>
   </a>
</div>
<!-- partial -->
  <script>
  	let c = document.querySelector('#triangles').getContext('2d')
let canvas = c.canvas;
let triangles = []

let mx = 0, my = 0;
let mouseHandler = event => {
   let mx = event.pageX / 100
   let my = event.pageY / 100
   
   document.querySelector('.bg').style.backgroundPosition = `${mx}px ${my}px`
   document.querySelector('.menu').style.transform = `translate(${mx * 2}px, ${my * 2}px)`
}

let loop = () => {
   c.clearRect(0, 0, canvas.width, canvas.height)
   
   triangles.forEach(triangle => {
      let { x, y, brightness } = triangle
      c.fillStyle = `rgba(${brightness * 128}, ${brightness * 128}, ${brightness * 128}, 1)`
      c.beginPath()
      c.moveTo(x + brightness * 32, y)
      c.lineTo(x, y - brightness * 48)
      c.lineTo(x - brightness * 32, y)
      c.fill()
      
      triangle.y -= brightness / 2
      if (triangle.y < -48 * brightness) {
         triangle.y = canvas.height + 48 * brightness;
      }
   })
   requestAnimationFrame(loop)
}

for (let i = 0; i < 32; i++) {
   triangles.push({
      x: Math.random() * canvas.width,
      y: Math.random() * canvas.height,
      brightness: 1 + Math.random()
   })
}

window.addEventListener('mousemove', mouseHandler)

loop()
  </script>

</body>
</html>
"""
		self.write(html)
