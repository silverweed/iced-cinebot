http   = require 'http'
url    = require 'url'
fs     = require 'fs'
path   = require 'path'
parser = require './cineparser.iced'

cwd = path.dirname fs.realpathSync __filename
console.log "cwd = #{cwd}"
port = 8888
opts = { useCache: true }
if fs.existsSync "#{cwd}/api.key"
	parser.apiKey = fs.readFileSync "#{cwd}/api.key", 'utf8'

http.createServer((req, resp) ->
	u = url.parse req.url, true
	switch u.pathname
		when '/process'
			parser.reset()
			parser.once 'ready', (data) =>
				resp.writeHead 200, { "Content-Type": "text/plain; charset=utf-8" }
				resp.end parser.emitCode(), 'utf8'
				console.log "Processed in #{(new Date() - @time)} ms."

			if u.query.dates.length > 0
				parser.setDates u.query.dates
			if u.query.v
				opts.csVersion = u.query.v
			@time = new Date()
			parser.parse u.query.page, opts
		else
			resp.writeHead 200, { "Content-Type": "text/html" }
			resp.end fs.readFileSync "#{cwd}/index.html", 'utf8'
).listen port

console.log "Serving on port #{port}\nusing cache: #{opts.useCache}"
