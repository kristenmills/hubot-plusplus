# Description:
#   Give or take away points. Keeps track and even prints out graphs.
#
# Dependencies:
#   "underscore": ">= 1.0.0"
#   "clark": "0.0.6"
#
# Configuration:
#
# Commands:
#   <name>++
#   <name>--
#   hubot score <name> [for <reason>]
#   hubot top <amount>
#   hubot bottom <amount>
#   hubot erase <user> [<reason>]
#   GET http://<url>/hubot/scores[?name=<name>][&direction=<top|botton>][&limit=<10>]
#
# Author:
#   ajacksified


_ = require('underscore')
clark = require('clark')
querystring = require('querystring')
ScoreKeeper = require('./scorekeeper')

module.exports = (robot) ->
  scoreKeeper = new ScoreKeeper(robot)

  listenerMetadata =
    vote:
      id: 'plusplus.vote'
      help: [
        '<user++ - add points to a user'
        '<user>-- - remove points from a user'
      ]
    erase:
      id: 'plusplus.erase'
      help: 'hubot erase <user> - erase all points for a user'
    score:
      id: 'plusplus.score'
      help: 'hubot score <user> - gets the score fore a specific user'
    topBottom:
      id: 'plusplus.top-bottom'
      help: [
        'hubot top <n> - gets the top `n` users and their scores'
        'hubot bottom <n> - gets the bottom `n` users and their scores'
      ]

  # sweet regex bro
  robot.hear ///
    # from beginning of line
    ^
    # the thing being upvoted, which is any number of words and spaces
    ([\s\w'@.-:]*)
    # allow for spaces after the thing being upvoted (@user ++)
    \s*
    # the increment/decrement operator ++ or --
    ([-+]{2}|—)
    # optional reason for the plusplus
    (?:\s+(?:for|because|cause|cuz)\s+(.+))?
    $ # end of line
  ///i,  listenerMetadata.vote, (msg) ->
    # let's get our local vars in place
    [dummy, name, operator, reason] = msg.match
    from = msg.message.user.name.toLowerCase()
    room = msg.message.room

    # do some sanitizing
    reason = reason?.trim().toLowerCase()
    name = (name.replace /(^\s*@)|([,:\s]*$)/g, "").trim().toLowerCase() if name

    # check whether a name was specified. use MRU if not
    unless name? && name != ''
      [name, lastReason] = scoreKeeper.last(room)
      reason = lastReason if !reason? && lastReason?

    user = robot.brain.userForName(name)
    if user?
      # do the {up, down}vote, and figure out what the new score is
      [score, reasonScore] = if operator == "++"
                scoreKeeper.add(user.id, from, room, reason)
              else
                scoreKeeper.subtract(user.id, from, room, reason)

      # if we got a score, then display all the things and fire off events!
      if score?
        message = if reason?
                    if reasonScore == 1 or reasonScore == -1
                      "#{user.name} has #{score} points, #{reasonScore} of which is for #{reason}."
                    else
                      "#{user.name} has #{score} points, #{reasonScore} of which are for #{reason}."
                  else
                    if score == 1
                      "#{user.name} has #{score} point."
                    else
                      "#{user.name} has #{score} points."


        msg.send message

        robot.emit "plus-one", {
          name: name
          direction: operator
          room: room
          reason: reason
        }
    else
      msg.send "I don't know who #{name} is."

  robot.respond ///
    (?:erase )
    # thing to be erased
    ([\s\w'@.-]+?)
    # optionally erase a reason from thing
    (?:\s+(?:for|because|cause|cuz)\s+(.+))?
    $ # eol
  ///i, listenerMetadata.erase, (msg) ->
    [__, name, reason] = msg.match
    from = msg.message.user.name.toLowerCase()
    user = msg.envelope.user
    room = msg.message.room
    reason = reason?.trim().toLowerCase()
    name = (name.replace /(^\s*@)|([,:\s]*$)/g, "").trim().toLowerCase() if name
    userId = robot.brain.userForName?(name).id;

    isAdmin = robot.auth?.hasRole(user, 'plusplus-admin') or robot.auth?.hasRole(user, 'admin')

    if not robot.auth? or isAdmin
      erased = scoreKeeper.erase(userId, from, room, reason)
    else
      return msg.reply "Sorry, you don't have authorization to do that."

    if erased?
      message = if reason?
                  "Erased the following reason from #{name}: #{reason}"
                else
                  "Erased points for #{name}"
      msg.send message

  robot.respond /score (for\s)?(.*)/i, listenerMetadata.score, (msg) ->
    name = msg.match[2].trim().toLowerCase()
    userId = robot.brain.userForName?(name).id;
    score = scoreKeeper.scoreForUser(userId)
    reasons = scoreKeeper.reasonsForUser(userId)

    reasonString = if typeof reasons == 'object' && Object.keys(reasons).length > 0
                     "#{name} has #{score} points. here are some raisins:" +
                     _.reduce(reasons, (memo, val, key) ->
                       memo += "\n#{key}: #{val} points"
                     , "")
                   else
                     "#{name} has #{score} points."

    msg.send reasonString

  robot.respond /(top|bottom) (\d+)/i, listenerMetadata.topBottom, (msg) ->
    amount = parseInt(msg.match[2]) || 10
    message = []

    tops = scoreKeeper[msg.match[1]](amount)

    if tops.length > 0
      for i in [0..tops.length-1]
        message.push("#{i+1}. #{robot.brain.userForId(tops[i].name).name} : #{tops[i].score}")
    else
      message.push("No scores to keep track of yet!")

    if(msg.match[1] == "top")
      graphSize = Math.min(tops.length, Math.min(amount, 20))
      message.splice(0, 0, clark(_.first(_.pluck(tops, "score"), graphSize)))

    msg.send message.join("\n")

  robot.router.get "/#{robot.name}/normalize-points", (req, res) ->
    scoreKeeper.normalize((score) ->
      if score > 0
        score = score - Math.ceil(score / 10)
      else if score < 0
        score = score - Math.floor(score / 10)

      score
    )

    res.end JSON.stringify('done')

  robot.router.get "/#{robot.name}/scores", (req, res) ->
    query = querystring.parse(req._parsedUrl.query)

    if query.name
      obj = {}
      obj[query.name] = scoreKeeper.scoreForUser(query.name)
      res.end JSON.stringify(obj)
    else
      direction = query.direction || "top"
      amount = query.limit || 10

      tops = scoreKeeper[direction](amount)

      res.end JSON.stringify(tops, null, 2)
