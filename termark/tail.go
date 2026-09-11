package termark

// tailFinder implements the commit rule: the last top-level block of the
// document is the tail (the only part future input can change); everything
// before it is final and committed once into an append-only cache.
//
// Per tick it re-parses the buffer, locates the last top-level block, commits
// any newly-stable bytes into the cache (rendered exactly once, followed by a
// blank separator), and renders the tail as a standalone fragment.
type tailFinder struct {
	fr           *fragmentRenderer
	committedEnd int    // byte offset just past the committed prefix
	cache        []Line // committed lines (append-only)
}

func newTailFinder(fr *fragmentRenderer) *tailFinder {
	return &tailFinder{fr: fr}
}

// tick renders the tail of buf and commits any newly-stable blocks. It returns
// the newly committed lines (nil when nothing new committed) and the tail
// lines. committedEnd is monotone; the cache is append-only.
func (tf *tailFinder) tick(buf []byte) (newCommitted, tail []Line) {
	blocks := tf.fr.topLevelBlocks(buf)
	if len(blocks) == 0 {
		return nil, nil
	}
	stableEnd := precedingBlankStart(buf, blocks[len(blocks)-1].Start)
	if stableEnd > tf.committedEnd {
		committed := tf.fr.render(buf[tf.committedEnd:stableEnd])
		if len(committed) > 0 {
			committed = append(committed, Line{}) // blank separator before the tail
			tf.cache = append(tf.cache, committed...)
			newCommitted = committed
		}
		tf.committedEnd = stableEnd
	}
	tail = tf.fr.render(buf[stableEnd:])
	return newCommitted, tail
}
