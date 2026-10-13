'use strict';
(function () {
    if (!window.videojs || !videojs.Vhs || !videojs.Vhs.xhr.onRequest) return;

    var webmItags = new Map();

    function itagOf(uri) {
        try {
            return new URL(uri, location.href).searchParams.get('itag');
        } catch (e) {
            return null;
        }
    }

    function isWebm(uri) { return webmItags.has(itagOf(uri)); }

    function readVint(b, p) {
        var first = b[p], length = 1, mask = 0x80;
        while (length <= 8 && !(first & mask)) { length++; mask >>= 1; }
        if (length > 8) throw new Error('bad EBML size at ' + p);
        var value = first & (mask - 1), unknown = value === mask - 1;
        for (var i = 1; i < length; i++) {
            value = value * 256 + b[p + i];
            if (b[p + i] !== 0xff) unknown = false;
        }
        return { value: unknown ? -1 : value, length: length };
    }

    function eachElement(b, start, end, fn) {
        var p = start;
        while (p < end) {
            var idLength = 1, mask = 0x80;
            while (idLength <= 4 && !(b[p] & mask)) { idLength++; mask >>= 1; }
            var id = 0;
            for (var i = 0; i < idLength; i++) id = id * 256 + b[p + i];
            var size = readVint(b, p + idLength);
            var data = p + idLength + size.length;
            var dataEnd = size.value < 0 ? end : Math.min(data + size.value, end);
            fn(id, data, dataEnd, size.value);
            p = dataEnd;
        }
    }

    function uint(b, s, e) {
        var v = 0;
        for (var i = s; i < e; i++) v = v * 256 + b[i];
        return v;
    }

    function float(b, s, e) {
        var view = new DataView(b.buffer, b.byteOffset + s, e - s);
        return e - s === 4 ? view.getFloat32(0) : view.getFloat64(0);
    }

    function parseHeader(b) {
        var out = { timestampScale: 1000000, duration: 0, track: {}, cues: [] };
        eachElement(b, 0, b.length, function (id, s, e, size) {
            if (id !== 0x18538067) return;
            out.segmentData = s;
            out.segmentEnd = size < 0 ? -1 : s + size;
            eachElement(b, s, e, function (id, s, e) {
                if (id === 0x1549A966) {
                    eachElement(b, s, e, function (id, s, e) {
                        if (id === 0x2AD7B1) out.timestampScale = uint(b, s, e);
                        else if (id === 0x4489) out.duration = float(b, s, e);
                    });
                } else if (id === 0x1654AE6B) {
                    eachElement(b, s, e, function (id, s, e) {
                        if (id === 0xAE) parseTrack(b, s, e, out.track);
                    });
                } else if (id === 0x1C53BB6B) {
                    out.cuesEnd = e;
                    eachElement(b, s, e, function (id, s, e) {
                        if (id !== 0xBB) return;
                        var cue = {};
                        eachElement(b, s, e, function (id, s, e) {
                            if (id === 0xB3) cue.time = uint(b, s, e);
                            else if (id === 0xB7) eachElement(b, s, e, function (id, s, e) {
                                if (id === 0xF1) cue.position = uint(b, s, e);
                            });
                        });
                        out.cues.push(cue);
                    });
                }
            });
        });
        return out;
    }

    function parseTrack(b, s, e, track) {
        eachElement(b, s, e, function (id, s, e) {
            if (id !== 0xE0) return;
            eachElement(b, s, e, function (id, s, e) {
                if (id === 0xB0) track.width = uint(b, s, e);
                else if (id === 0xBA) track.height = uint(b, s, e);
                else if (id === 0x55B0) eachElement(b, s, e, function (id, s, e) {
                    if (id === 0x55D0) {
                        track.mastering = {};
                        return eachElement(b, s, e, function (id, s, e) { track.mastering[id] = float(b, s, e); });
                    }
                    var v = uint(b, s, e);
                    if (id === 0x55B2) track.bitDepth = v;
                    else if (id === 0x55B1) track.matrix = v;
                    else if (id === 0x55BA) track.transfer = v;
                    else if (id === 0x55BB) track.primaries = v;
                    else if (id === 0x55B9) track.fullRange = v === 2;
                    else if (id === 0x55BC) track.maxCLL = v;
                    else if (id === 0x55BD) track.maxFALL = v;
                });
            });
        });
    }

    function parseClusters(b) {
        var frames = [];
        function block(s, e, clusterTime, key) {
            var track = readVint(b, s);
            var p = s + track.length;
            var flags = b[p + 2];
            if (flags & 0x06) throw new Error('laced blocks are not supported');
            frames.push({
                time: clusterTime + ((b[p] << 24 >> 16) | b[p + 1]),
                key: key === undefined ? !!(flags & 0x80) : key,
                start: p + 3,
                end: e
            });
        }
        eachElement(b, 0, b.length, function (id, s, e) {
            if (id !== 0x1F43B675) return;
            var clusterTime = 0;
            eachElement(b, s, e, function (id, s, e) {
                if (id === 0xE7) clusterTime = uint(b, s, e);
                else if (id === 0xA3) block(s, e, clusterTime);
                else if (id === 0xA0) {
                    var found = null, references = false;
                    eachElement(b, s, e, function (id, s, e) {
                        if (id === 0xA1) found = [s, e];
                        else if (id === 0xFB) references = true;
                    });
                    if (found) block(found[0], found[1], clusterTime, !references);
                }
            });
        });
        return frames;
    }

    function concat(parts) {
        var size = 0, i;
        for (i = 0; i < parts.length; i++) size += parts[i].length;
        var out = new Uint8Array(size), offset = 0;
        for (i = 0; i < parts.length; i++) { out.set(parts[i], offset); offset += parts[i].length; }
        return out;
    }

    function u8(n) { return new Uint8Array([n]); }
    function u16(n) { return new Uint8Array([n >>> 8 & 255, n & 255]); }
    function u32(n) { var a = new Uint8Array(4); new DataView(a.buffer).setUint32(0, n >>> 0); return a; }
    function u64(n) { return concat([u32(Math.floor(n / 4294967296)), u32(n % 4294967296)]); }
    function str(s) { return new Uint8Array(s.split('').map(function (c) { return c.charCodeAt(0); })); }
    function zeros(n) { return new Uint8Array(n); }

    function box(type, parts) {
        var body = concat(parts || []);
        return concat([u32(body.length + 8), str(type), body]);
    }

    function fullBox(type, version, flags, parts) {
        return box(type, [u8(version), u8(flags >>> 16 & 255), u16(flags & 0xffff)].concat(parts || []));
    }

    var MATRIX = concat([u32(0x10000), u32(0), u32(0), u32(0), u32(0x10000), u32(0), u32(0), u32(0), u32(0x40000000)]);

    function vp9Profile(bitDepth) { return bitDepth > 8 ? 2 : 0; }
    function vp9Level(height) { return height > 1080 ? 51 : height > 720 ? 41 : 31; }

    function hdrBoxes(t) {
        var out = [], m = t.mastering;
        if (m) {
            var chroma = function (id, unit) { return u16(Math.round((m[id] || 0) / unit) & 0xffff); };
            var order = [0x55D3, 0x55D4, 0x55D5, 0x55D6, 0x55D1, 0x55D2, 0x55D7, 0x55D8];
            out.push(box('mdcv', order.map(function (id) { return chroma(id, 0.00002); })
                .concat([u32(Math.round((m[0x55D9] || 0) * 10000)), u32(Math.round((m[0x55DA] || 0) * 10000))])));
            var rgbw = [0x55D1, 0x55D2, 0x55D3, 0x55D4, 0x55D5, 0x55D6, 0x55D7, 0x55D8];
            out.push(fullBox('SmDm', 0, 0, rgbw.map(function (id) { return chroma(id, 1 / 65536); })
                .concat([u32(Math.round((m[0x55D9] || 0) * 256)), u32(Math.round((m[0x55DA] || 0) * 16384))])));
        }
        if (t.maxCLL !== undefined) {
            out.push(box('clli', [u16(t.maxCLL), u16(t.maxFALL || 0)]));
            out.push(fullBox('CoLL', 0, 0, [u16(t.maxCLL), u16(t.maxFALL || 0)]));
        }
        return out;
    }

    function initSegment(header, tenBit) {
        var t = header.track, timescale = 1e9 / header.timestampScale;
        var bitDepth = t.bitDepth || (tenBit ? 10 : 8);
        var vpcC = fullBox('vpcC', 1, 0, [
            u8(vp9Profile(bitDepth)), u8(vp9Level(t.height)),
            u8(bitDepth << 4 | 1 << 1 | (t.fullRange ? 1 : 0)),
            u8(t.primaries || 1), u8(t.transfer || 1), u8(t.matrix || 1), u16(0)
        ]);
        var vp09 = box('vp09', [
            zeros(6), u16(1), zeros(16), u16(t.width), u16(t.height),
            u32(0x480000), u32(0x480000), u32(0), u16(1), zeros(32), u16(0x18), u16(0xffff), vpcC,
            box('colr', [str('nclx'), u16(t.primaries || 1), u16(t.transfer || 1), u16(t.matrix || 1), u8(t.fullRange ? 0x80 : 0)])
        ].concat(hdrBoxes(t)));
        var stbl = box('stbl', [
            fullBox('stsd', 0, 0, [u32(1), vp09]),
            fullBox('stts', 0, 0, [u32(0)]),
            fullBox('stsc', 0, 0, [u32(0)]),
            fullBox('stsz', 0, 0, [u32(0), u32(0)]),
            fullBox('stco', 0, 0, [u32(0)])
        ]);
        var minf = box('minf', [
            fullBox('vmhd', 0, 1, [zeros(8)]),
            box('dinf', [fullBox('dref', 0, 0, [u32(1), fullBox('url ', 0, 1)])]),
            stbl
        ]);
        var mdia = box('mdia', [
            fullBox('mdhd', 0, 0, [u32(0), u32(0), u32(timescale), u32(0), u16(0x55C4), u16(0)]),
            fullBox('hdlr', 0, 0, [u32(0), str('vide'), zeros(12), str('VideoHandler'), u8(0)]),
            minf
        ]);
        var trak = box('trak', [
            fullBox('tkhd', 0, 3, [u32(0), u32(0), u32(1), u32(0), u32(0), zeros(8), u16(0), u16(0), u16(0), u16(0),
                MATRIX, u32(t.width * 65536), u32(t.height * 65536)]),
            mdia
        ]);
        var moov = box('moov', [
            fullBox('mvhd', 0, 0, [u32(0), u32(0), u32(timescale), u32(0), u32(0x10000), u16(0x100), zeros(10),
                MATRIX, zeros(24), u32(2)]),
            trak,
            box('mvex', [fullBox('trex', 0, 0, [u32(1), u32(1), u32(0), u32(0), u32(0)])])
        ]);
        return concat([box('ftyp', [str('iso6'), u32(0), str('iso6'), str('dash')]), moov]);
    }

    function sidx(header, clen) {
        var timescale = 1e9 / header.timestampScale;
        var seen = {}, cues = header.cues.filter(function (c) {
            if (c.position === undefined || seen[c.position]) return false;
            return (seen[c.position] = true);
        }).sort(function (a, b) { return a.position - b.position; });
        if (!cues.length) throw new Error('no Cues');
        var end = header.segmentEnd > 0 ? header.segmentEnd : clen;
        var refs = cues.map(function (cue, i) {
            var next = cues[i + 1];
            var size = (next ? next.position : end - header.segmentData) - cue.position;
            var duration = (next ? next.time : header.duration) - cue.time;
            return concat([u32(size & 0x7fffffff), u32(Math.max(0, Math.round(duration))), u32(0x90000000)]);
        });
        var firstOffset = header.segmentData + cues[0].position - header.cuesEnd;
        return fullBox('sidx', 0, 0, [u32(1), u32(timescale), u32(cues[0].time), u32(firstOffset), u16(0), u16(refs.length)].concat(refs));
    }

    var sequence = 0;

    function fragment(b) {
        var frames = parseClusters(b);
        if (!frames.length) throw new Error('no frames');
        var samples = frames.map(function (f, i) {
            var next = frames[i + 1], previous = frames[i - 1];
            var duration = next ? next.time - f.time : previous ? f.time - previous.time : 0;
            return concat([u32(duration), u32(f.end - f.start), u32(f.key ? 0x02000000 : 0x01010000)]);
        });
        var moofSize = 8 + 16 + 8 + 16 + 20 + 20 + 12 * frames.length;
        var moof = box('moof', [
            fullBox('mfhd', 0, 0, [u32(++sequence)]),
            box('traf', [
                fullBox('tfhd', 0, 0x020000, [u32(1)]),
                fullBox('tfdt', 1, 0, [u64(frames[0].time)]),
                fullBox('trun', 0, 0x000701, [u32(frames.length), u32(moofSize + 8)].concat(samples))
            ])
        ]);
        var mdat = box('mdat', frames.map(function (f) { return b.subarray(f.start, f.end); }));
        return concat([moof, mdat]);
    }

    var hdrScreen = window.matchMedia && matchMedia('(dynamic-range: high)').matches;

    function rewriteManifest(request) {
        var doc = new DOMParser().parseFromString(request.responseText, 'application/xml');
        var sets = doc.querySelectorAll('AdaptationSet[mimeType="video/webm"]');
        if (!sets.length) return;
        sets.forEach(function (set) {
            set.setAttribute('mimeType', 'video/mp4');
            set.querySelectorAll('Representation').forEach(function (rep) {
                var codec = rep.getAttribute('codecs') || set.getAttribute('codecs') || '';
                if (!/^vp0?9/.test(codec)) return;
                var level = vp9Level(parseInt(rep.getAttribute('height')) || 0);
                var tenBit = /^vp9\.2|^vp09\.02/.test(codec);
                if (tenBit && !hdrScreen) return rep.parentNode.removeChild(rep);
                rep.setAttribute('codecs', tenBit ? 'vp09.02.' + level + '.10.01.09.16.09.00' : 'vp09.00.' + level + '.08');
                webmItags.set(rep.getAttribute('id'), tenBit);
            });
            set.removeAttribute('codecs');
        });
        Object.defineProperty(request, 'responseText', {
            value: new XMLSerializer().serializeToString(doc), configurable: true
        });
    }

    var FTYP_TEXT = String.fromCharCode.apply(null, box('ftyp', [str('iso6'), u32(0), str('iso6'), str('dash')]));

    videojs.Vhs.xhr.onRequest(function (options) {
        if (!isWebm(options.uri)) return options;
        var range = options.headers && options.headers.Range;
        if (!range && !options.requestType) {
            var beforeSend = options.beforeSend;
            options.beforeSend = function (xhr) {
                if (beforeSend) beforeSend(xhr);
                Object.defineProperty(xhr, 'responseText', { get: function () { return FTYP_TEXT; } });
            };
        } else if (options.requestType === 'dash-sidx' && range) {
            options.headers = Object.assign({}, options.headers, { Range: 'bytes=0-' + range.split('-')[1] });
        }
        return options;
    });

    videojs.Vhs.xhr.onResponse(function (request, error) {
        if (error) return;
        try {
            if (request.requestType === 'dash-manifest') return rewriteManifest(request);
            if (!isWebm(request.uri) || !request.response) return;
            var b = new Uint8Array(request.response), out = null;
            if (request.requestType === 'dash-sidx') {
                var clen = parseInt(new URL(request.uri, location.href).searchParams.get('clen')) || 0;
                out = sidx(parseHeader(b), clen);
            } else if (request.requestType === 'segment-media-initialization') {
                out = initSegment(parseHeader(b), webmItags.get(itagOf(request.uri)));
            } else if (request.requestType === 'segment') {
                out = fragment(b);
            }
            if (out) Object.defineProperty(request, 'response', { value: out.buffer, configurable: true });
        } catch (e) {
            videojs.log.warn('webm_fmp4: could not convert', request.requestType, e);
        }
    });

})();
