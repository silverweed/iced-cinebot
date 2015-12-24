# Fetches a page from comingsoon.it, parses it and fills cineteatrosanluigi
# template.
# by silverweed
cheerio = require 'cheerio'
fs      = require 'fs'
path    = require 'path'
http    = require 'http'
https   = require 'https'
exec    = require('child_process').exec
EventEmitter = require('events').EventEmitter

cwd = path.dirname fs.realpathSync __filename

class Parser
	LATEST_CS_VERSION: 2

	constructor: ->
		@data = {}
		@yturl = null
		@type = 'CS'
		@dataReady = false
		@dates = []
		@ee = new EventEmitter()
		@apiKey = null
		@ytReady = false

	ready: (what) ->
		switch what
			when 'yt'
				@ytReady = true
				@ee.emit 'ready' if @dataReady
			when 'data'
				@dataReady = true
				@ee.emit 'ready' if @ytReady

	# Concurrently fetches data from CS and YT and parses HTML data from fetched page.
	# If opts.useCache == true, try reading locally saved data if possible.
	parse: (url, opts) ->
		console.log "------------------#{new Date()}------------------"
		console.log "** Requested URL: #{url}"
		files = do ->
			f = url.split('/')[4]
			{
				base:     f
				full:     "#{cwd}/#{f}"
				pages:    "#{cwd}/pages/#{f}"
				videoIds: "#{cwd}/videoIds/#{f}"
			}
		opts.files = files

		@createDirs "pages", "videoIDs"

		# Fetch youtube video
		if @apiKey?
			@ytReady = false
			ytQuery = 'https://www.googleapis.com/youtube/v3/search?part=id&q=' +
				files.base.replace(/-/g, '+') +
				'+trailer+ita&videoEmbeddable=true&maxResults=1&regionCode=IT&type=video&key=' + @apiKey

			# Try using cached ID
			if opts?.useCache and fs.existsSync files.videoIds
				console.log "** Using cached videoId: #{files.videoIds}"
				await fs.readFile files.videoIds, 'utf-8', defer err, data
				if err
					@queryYT ytQuery, opts
					return this
				@yturl = data
				console.log "**** YT: read cached videoId: #{_this.yturl}"
				@ready 'yt'
			else
				@queryYT ytQuery, opts
		else
			console.log "** No YT API key: skipping trailer."
			@ready 'yt'

		# Parse Comingsoon HTML page
		if opts?.useCache and fs.existsSync files.pages
			console.log "** Using cached page: #{files.pages}"
			@parseCS(cheerio.load(fs.readFileSync(files.pages, 'utf-8')), opts.csVersion)
			console.log "**** Parsed page: #{files.pages}"
			return this

		console.log "** GET page: #{url}"
		await http.get url, defer resp
		body = ''
		resp.on 'data', (d) -> body += d
		resp.on 'end', =>
			$ = cheerio.load body
			# Concurrently parse page and save it
			console.log '**** Page received. Parsing...'
			@parseCS $, opts.csVersion
			console.log "**** Parsed page: #{files.pages}"
			if opts?.useCache
				await fs.writeFile files.pages, $('.contenitore-scheda').html(), defer err
				throw err if err
				console.log "** Cached page: #{files.pages}"
				return this

		resp.on 'error', (e) -> console.log "[!!] Error getting page: #{e}"

	queryYT: (ytQuery, opts) ->
		console.log "** Querying YouTube API: #{ytQuery}"

		await https.get ytQuery, defer resp
		body = ''
		resp.on 'data', (d) -> body += d
		resp.on 'end', =>
			console.log "**** Received from YouTube: #{body}"
			video = JSON.parse body
			unless video.items?[0]?.id?
				console.log "[!!] Invalid response from YouTube API: #{video}"
				@ready 'yt'
				return
			@yturl = video.items[0].id.videoId
			console.log "**** YT: received videoId: #{@yturl}"
			@ready 'yt'
			if opts?.useCache
				await fs.writeFile opts.files.videoIds, @yturl, defer err
				throw err if err
				console.log "** Cached videoId: #{opts.files.videoIds} (#{@yturl})"
				return this
		resp.on 'error', (e) -> console.log "[!!] Error querying YT: #{e}"

	# parse a Comingsoon.it page subsequent calls to emitCode() will use 
	# data from this page until a new parseCS will be called.
	# Argument: a Cheerio parser [optional] the Comingsoon format version
	# (null = latest 1: "old", 2: "new")
	parseCS: ($, csVersion) ->
		@dataReady = false
		@data = {}
		csVersion = +csVersion ? Parser.LATEST_CS_VERSION
		if csVersion < 1 or csVersion > Parser.LATEST_CS_VERSION
			csVersion = Parser.LATEST_CS_VERSION
		console.log "**** Using csVersion = #{csVersion}"
		
		plotClassName = [
					'.product-profile-box-toprow-text'
					'.contenuto-scheda-destra'
				][csVersion - 1]

		# Traverse HTML tree and gather data
		# The plot is the last child of '.contenuto-scheda-destra'
		@data.plot = $(plotClassName).children().last().text().trim()
		if @data.plot.length > 350
			# split in preplot and postplot
			idx = -1
			start = 300
			cycles = 0
			while (idx < 0 or idx > 400) and cycles++ < 20
				idx = @data.plot.indexOf '.', start
				if  idx < 0 or idx > 400
					idx = @data.plot.indexOf '!', start
					if idx < 0 or idx > 400
						idx = @data.plot.indexOf '?', start
				start -= 10

			if idx < 0 or idx > 400
				console.log "Warning: couldn't auto split plot. Please split it manually."
				@data.preplot = @data.plot
			else
				@data.preplot = @data.plot[0..idx]
				@data.postplot = @data.plot[idx + 1 ..]
				if @data.postplot
					@data.postplot = @data.postplot.trim()
		else
			@data.preplot = @data.plot
			@data.postplot = null

		listClassName = [
					'div.product-profile-box-middlerow-left ul li',
					'div.box-descrizione ul li'
				][csVersion - 1]
		cname = ['strong', 'span'][csVersion - 1]
		list = $(listClassName)
		for li in list
			for c in li.children
				if c.name == cname
					switch c.children[0].data
						when "GENERE"
							@data.genre = c.next.next.children[0].data
						when "ANNO"
							@data.year = c.next.next.children[0].data
						when "REGIA"
							@data.direction = c.next.next.children[0].data
						when "ATTORI"
							@data.cast = li.children.filter((e) ->
								e.name == 'a' && e.attribs && e.attribs.itemprop == 'actor'
							).map((e) ->
								e.children[0].data
							)[0..10]
						when "PAESE"
							@data.country = c.next.data[2..]
						when "DURATA"
							dtime = c.next.next.attribs.datetime
							@data.duration = @parseDuration dtime[2..dtime.length]
		@ready 'data'
		return this

	parseDuration: (min) ->
		dur = parseInt min, 10
		hours = Math.floor dur / 60
		(if hours > 0
			"#{hours + (if hours > 1 then " ore" else " ora")} e "
		else
			""
		) +
		(if dur - hours * 60 > 0
			"#{dur - hours * 60} minuti"
		else
			""
		)

	createDirs: (dirs...) ->
		errs = []
		await
			for dir, i in dirs
				fs.mkdir dir, defer errs[i]
		for err in errs
			throw err if err? and err.code != 'EEXIST'

	# Fill cineteatro template with data. Should only be called when dataReady == true. For ease of writing,
	# this function is compiled from Coffeescript.
	emitCode: ->
		"""<head>
		<style>
		li.orario
		{
		  margin-top: 15px;
		  color: #000;
		  font-size: large;
		}
		</style>
		</head>
		<div style="float: left; margin: 15px 15px 15px 0px;">
		    #{if @yturl?
			    "<iframe src='http://www.youtube.com/embed/#{@yturl}?iv_load_policy=3&start=12' height='260' width='320' allowfullscreen='' frameborder='0'></iframe>"
		    else
			    "<!-- <iframe src='http://www.youtube.com/embed/INSERIRE_VIDEO_ID?iv_load_policy=3&start=12' height='260' width='320' allowfullscreen='' frameborder='0'></iframe> -->"}
		</div>
		<strong>IN SALA:</strong>
		<ul style="margin-left: 450px; font-family: arial;">
		#{if @dates.length > 0
			("\t<li class=\"orario\">#{date}</li>" for date in @dates).join "\n"
		else "	<!-- <li class=\"orario\">Inserire l'orario</li> -->"}
		</ul>

		#{@data.preplot}
		<!--more-->
		#{@data.postplot ? ""}

		<br clear="left" />

		<strong>GENERE:</strong> #{@data.genre}

		<strong>NAZIONE E ANNO:</strong> #{@data.country} #{@data.year}

		<strong>DURATA:</strong> #{@data.duration}

		<strong>REGIA:</strong> #{@data.direction}

		<strong>CAST:</strong>
		<ul>
		#{if @data.cast?.map? then (@data.cast.map (e) -> return "\t<li>#{e}</li>").join "\n"}
		</ul>

		<strong>PREZZI:</strong>
		- <em>Intero:</em> 6 €
		- <em>Ridotto</em>: 4,50 €
		"""

	on: (sel, cb) -> @ee.on sel, cb
	once: (sel, cb) -> @ee.once sel, cb

	setDates: (rawdates) ->
		lines = rawdates.split "\n"
		for i in [0..lines.length]
			m = lines[i].match /// ^\s*
				(Luned.
				|Marted.
				|Mercoled.
				|Gioved.
				|Venerd.
				|Sabato
				|Domenica
				) ([0-9]+) (?:alle )?ore ([0-9\-:.,]+)
				\s*$
				///i
			if m?
				if m[1][0] != 'S' and m[1][0] != 'D'
					m[1] = "#{m[1][0...m[1].length - 1]}ì"
				if m[3].length == 2
					m[3] += ':00'
				@dates.push "#{m[1]} #{m[2]} alle ore #{m[3]}"

	reset: ->
		@data = {}
		@dataReady = false
		@ytReady = false
		@dates = []

module.exports = new Parser()
