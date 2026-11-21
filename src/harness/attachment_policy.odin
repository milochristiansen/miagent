// Attachment migration and retention policy.
//
// Policy is size-tiered and pressure-aware. Pressure uses every distinct blob
// referenced by the live session, including omitted placeholders, so recalling
// an existing attachment does not increase pressure. When an eviction is
// unavoidable, a suffix sweep also clears likely future victims newer than the
// earliest changed item, because those tokens are already outside the cached
// prefix for that request.
package harness

import "core:encoding/base64"
import "core:fmt"
import "core:strings"

ATTACHMENT_TIER_T1 :: i64(256 * 1024)
ATTACHMENT_TIER_T2 :: i64(1024 * 1024)
ATTACHMENT_TIER_T3 :: i64(4 * 1024 * 1024)
BODY_TIER_T1 :: i64(64 * 1024)
BODY_TIER_T2 :: i64(256 * 1024)
POLICY_TIERS :: 5

Attachment_Info :: struct {
	blob:         string,
	size:         i64,
	first_item:   int,
	newest_item:  int,
	has_active:   bool,
	recent:       bool,
	protected:    bool,
}

Body_Info :: struct {
	item:      int,
	size:      i64,
	recent:    bool,
	protected: bool,
}

ceil_div_i64 :: proc(a, b: i64) -> i64 {
	if b <= 0 do return 1
	if a <= 0 do return 1
	return (a + b - 1) / b
}

attachment_tier :: proc(size: i64, small: i64) -> int {
	if size <= small do return 0
	if size <= ATTACHMENT_TIER_T1 do return 1
	if size <= ATTACHMENT_TIER_T2 do return 2
	if size <= ATTACHMENT_TIER_T3 do return 3
	return 4
}

attachment_base_keep :: proc(tier: int) -> int {
	switch tier {
	case 0: return 0 // unlimited
	case 1: return 16
	case 2: return 8
	case 3: return 4
	}
	return 2
}

body_tier :: proc(size: i64, small: i64) -> int {
	if size <= small do return 0
	if size <= BODY_TIER_T1 do return 1
	if size <= BODY_TIER_T2 do return 2
	return 3
}

body_base_keep :: proc(tier: int) -> int {
	switch tier {
	case 0: return 0
	case 1: return 12
	case 2: return 4
	}
	return 2
}

scaled_keep :: proc(base: int, pressure: i64) -> int {
	if base <= 0 do return 0
	p := pressure
	if p < 1 do p = 1
	keep := i64(base) / p
	if keep < 1 do keep = 1
	return int(keep)
}

// attachments_externalize moves legacy inline payloads and large tool-output
// bodies into the session blob store. It never transforms bytes.
attachments_externalize :: proc(
	session: ^Session,
	store: ^Attachment_Store,
	body_threshold: i64,
) -> (changed: bool, err: string) {
	for i in 0 ..< len(session.items) {
		it := &session.items[i]
		for j in 0 ..< len(it.attachments) {
			att := &it.attachments[j]
			if len(att.blob) > 0 do continue
			if len(att.url) > 0 {
				comma := strings.last_index_byte(att.url, ',')
				if comma <= 0 || !strings.contains(strings.to_lower(att.url[:comma]), ";base64") {
					return changed, fmt.aprintf("attachment %d on item %d has an invalid data URL", j, i)
				}
				decoded, derr := base64.decode(att.url[comma + 1:])
				if derr != nil {
					return changed, fmt.aprintf("attachment %d on item %d: base64 decode failed", j, i)
				}
				blob, berr := attachment_store_put(store, decoded)
				att.size = len(decoded)
				delete(decoded)
				if len(berr) > 0 do return changed, berr
				att.blob = blob
				delete(att.url)
				att.url = ""
				changed = true
				continue
			}
			if len(att.text) > 0 {
				data := transmute([]byte)att.text
				blob, berr := attachment_store_put(store, data)
				if len(berr) > 0 do return changed, berr
				att.size = len(data)
				att.blob = blob
				delete(att.text)
				att.text = ""
				changed = true
			}
		}

		if it.role != "function_call_output" do continue
		if len(it.output_blob) > 0 do continue
		if len(it.output) == 0 do continue
		if i64(len(it.output)) <= body_threshold && !it.output_omitted do continue
		data := transmute([]byte)it.output
		blob, berr := attachment_store_put(store, data)
		if len(berr) > 0 do return changed, berr
		it.output_blob = blob
		it.output_size = len(data)
		delete(it.output)
		it.output = ""
		changed = true
	}
	return changed, ""
}

collect_attachment_infos :: proc(
	items: []StoredItem,
	small: i64,
	recent_items: int,
	protected_items: map[int]bool,
) -> []Attachment_Info {
	infos := make([dynamic]Attachment_Info, 0, 16)
	index := make(map[string]int, 16)
	defer {
		for key in index do delete(key)
		delete(index)
	}
	recent_start := len(items) - recent_items
	if recent_start < 0 do recent_start = 0
	for i in 0 ..< len(items) {
		it := items[i]
		for att in it.attachments {
			if len(att.blob) == 0 do continue
			idx, exists := index[att.blob]
			if !exists {
				idx = len(infos)
				index[strings.clone(att.blob)] = idx
				append(&infos, Attachment_Info{
					blob = att.blob,
					size = i64(att.size),
					first_item = i,
					newest_item = i,
					recent = i >= recent_start,
				})
			}
			info := &infos[idx]
			if i64(att.size) > info.size do info.size = i64(att.size)
			if i > info.newest_item do info.newest_item = i
			if !att.omitted do info.has_active = true
			if protected_items[i] do info.protected = true
		}
	}
	return infos[:]
}

collect_body_infos :: proc(items: []StoredItem, small: i64, recent_items: int, protected_items: map[int]bool) -> []Body_Info {
	_ = small
	bodies := make([dynamic]Body_Info, 0, 8)
	recent_start := len(items) - recent_items
	if recent_start < 0 do recent_start = 0
	for i in 0 ..< len(items) {
		it := items[i]
		if it.role != "function_call_output" || it.output_omitted do continue
		size := i64(it.output_size)
		if size <= 0 do size = i64(len(it.output))
		if size <= 0 do continue
		append(&bodies, Body_Info{
			item = i,
			size = size,
			recent = i >= recent_start,
			protected = protected_items[i],
		})
	}
	return bodies[:]
}

sort_attachment_indices :: proc(infos: []Attachment_Info) -> []int {
	idx := make([]int, len(infos))
	for i in 0 ..< len(infos) do idx[i] = i
	for i in 1 ..< len(idx) {
		j := i
		for j > 0 {
			a, b := infos[idx[j]], infos[idx[j - 1]]
			before := false
			if a.newest_item != b.newest_item {
				before = a.newest_item > b.newest_item
			} else if a.size != b.size {
				before = a.size > b.size
			} else {
				before = a.blob < b.blob
			}
			if !before do break
			idx[j], idx[j - 1] = idx[j - 1], idx[j]
			j -= 1
		}
	}
	return idx
}

sort_body_indices :: proc(bodies: []Body_Info) -> []int {
	idx := make([]int, len(bodies))
	for i in 0 ..< len(bodies) do idx[i] = i
	for i in 1 ..< len(idx) {
		j := i
		for j > 0 {
			a, b := bodies[idx[j]], bodies[idx[j - 1]]
			before := false
			if a.item != b.item {
				before = a.item > b.item
			} else if a.size != b.size {
				before = a.size > b.size
			}
			if !before do break
			idx[j], idx[j - 1] = idx[j - 1], idx[j]
			j -= 1
		}
	}
	return idx
}

attachment_pressure :: proc(config: ^Config, infos: []Attachment_Info) -> i64 {
	known_count: i64 = i64(len(infos))
	known_bytes: i64 = 0
	recent_count: i64 = 0
	for info in infos {
		known_bytes += info.size
		if info.recent do recent_count += 1
	}
	count_pressure := ceil_div_i64(known_count, i64(max(config.attachment_pressure_count, 1)))
	byte_pressure := ceil_div_i64(known_bytes, max(config.attachment_pressure_bytes, 1))
	burst_pressure := ceil_div_i64(recent_count, i64(max(config.attachment_pressure_recent, 1)))
	return max(count_pressure, max(byte_pressure, burst_pressure))
}

body_pressure :: proc(config: ^Config, bodies: []Body_Info) -> i64 {
	count: i64 = 0
	bytes: i64 = 0
	recent: i64 = 0
	for b in bodies {
		count += 1
		bytes += b.size
		if b.recent do recent += 1
	}
	count_pressure := ceil_div_i64(count, i64(max(config.attachment_pressure_count, 1)))
	byte_pressure := ceil_div_i64(bytes, max(config.tool_body_send_budget, 1))
	burst_pressure := ceil_div_i64(recent, i64(max(config.attachment_pressure_recent, 1)))
	return max(count_pressure, max(byte_pressure, burst_pressure))
}

// attachment_policy_apply marks attachments and tool bodies omitted according
// to the retention rules. It returns whether anything changed.
attachment_policy_apply :: proc(config: ^Config, session: ^Session) -> (changed: bool, notes: string) {
	items := session.items[:]
	protected_items := make(map[int]bool, 2)
	defer delete(protected_items)
	newest_user := -1
	newest_tool := -1
	for it, i in items {
		switch it.role {
		case "user":
			newest_user = i
		case "function_call_output":
			newest_tool = i
		}
	}
	if newest_user >= 0 do protected_items[newest_user] = true
	if newest_tool >= 0 do protected_items[newest_tool] = true
	// Protect the entire current tool-output batch, not just its last item.
	// A model response can issue several calls; a recall in the first call must
	// not be pruned because a later call produced another output.
	batch := len(items) - 1
	for batch >= 0 && items[batch].role == "nugget" do batch -= 1
	for batch >= 0 && items[batch].role == "function_call_output" {
		protected_items[batch] = true
		batch -= 1
	}
	recall_extra: i64 = 0
	for i in protected_items {
		if items[i].recalled {
			recall_extra = config.recall_headroom
			break
		}
	}
	attach_budget := config.attachment_send_budget + recall_extra
	body_budget := config.tool_body_send_budget + recall_extra

	infos := collect_attachment_infos(items, config.attachment_small_bytes, config.attachment_recent_items, protected_items)
	defer delete(infos)
	bodies := collect_body_infos(items, config.tool_body_small_bytes, config.attachment_recent_items, protected_items)
	defer delete(bodies)

	attach_pressure := attachment_pressure(config, infos)
	body_pressure_value := body_pressure(config, bodies)

	attach_victim := make(map[string]bool, 8)
	defer delete(attach_victim)
	body_victim := make(map[int]bool, 8)
	defer delete(body_victim)

	attach_order := sort_attachment_indices(infos)
	defer delete(attach_order)
	body_order := sort_body_indices(bodies)
	defer delete(body_order)

	// Mandatory retention by size tier and pressure.
	kept_by_tier: [POLICY_TIERS]int
	for idx in attach_order {
		info := infos[idx]
		if !info.has_active do continue
		tier := attachment_tier(info.size, config.attachment_small_bytes)
		if info.protected || tier == 0 {
			kept_by_tier[tier] += 1
			continue
		}
		keep := scaled_keep(attachment_base_keep(tier), attach_pressure)
		if kept_by_tier[tier] >= keep {
			attach_victim[info.blob] = true
		} else {
			kept_by_tier[tier] += 1
		}
	}

	body_kept: [POLICY_TIERS]int
	for idx in body_order {
		b := bodies[idx]
		tier := body_tier(b.size, config.tool_body_small_bytes)
		if b.protected || tier == 0 {
			body_kept[tier] += 1
			continue
		}
		keep := scaled_keep(body_base_keep(tier), body_pressure_value)
		if body_kept[tier] >= keep {
			body_victim[b.item] = true
		} else {
			body_kept[tier] += 1
		}
	}

	// Hard budgets: keep removing the oldest non-tiny, non-protected payloads
	// until the active request set is under the configured caps.
	active_attach_bytes: i64 = 0
	active_attach_count: int = 0
	for info in infos {
		if !info.has_active || attach_victim[info.blob] do continue
		active_attach_bytes += info.size
		if attachment_tier(info.size, config.attachment_small_bytes) != 0 do active_attach_count += 1
	}
	for i := len(attach_order) - 1; i >= 0; i -= 1 {
		if active_attach_bytes <= attach_budget && active_attach_count <= config.attachment_max_active do break
		info := infos[attach_order[i]]
		if !info.has_active || info.protected || attach_victim[info.blob] do continue
		if attachment_tier(info.size, config.attachment_small_bytes) == 0 do continue
		attach_victim[info.blob] = true
		active_attach_bytes -= info.size
		active_attach_count -= 1
	}

	active_body_bytes: i64 = 0
	for b in bodies {
		if !body_victim[b.item] do active_body_bytes += b.size
	}
	for i := len(body_order) - 1; i >= 0; i -= 1 {
		if active_body_bytes <= body_budget do break
		b := bodies[body_order[i]]
		if b.protected || body_victim[b.item] do continue
		if body_tier(b.size, config.tool_body_small_bytes) == 0 do continue
		body_victim[b.item] = true
		active_body_bytes -= b.size
	}

	anchor := len(items) + 1
	// Compute the earliest changed item directly from the victim sets.
	for info in infos {
		if attach_victim[info.blob] && info.first_item < anchor do anchor = info.first_item
	}
	for b in bodies {
		if body_victim[b.item] && b.item < anchor do anchor = b.item
	}
	if anchor > len(items) do return false, ""

	// Cache-aware suffix sweep. Anything newer than the anchor is already
	// outside the cached prefix for this request, so clear likely future
	// victims now.
	if config.cache_sweep && anchor < len(items) {
		attach_suffix: [POLICY_TIERS]int
		for idx in attach_order {
			info := infos[idx]
			if !info.has_active || info.protected || attach_victim[info.blob] do continue
			if info.first_item <= anchor do continue
			tier := attachment_tier(info.size, config.attachment_small_bytes)
			if tier == 0 do continue
			keep := scaled_keep(attachment_base_keep(tier), attach_pressure)
			if config.sweep_aggression > 1 {
				sweep_keep := keep / config.sweep_aggression
				if sweep_keep < 1 do sweep_keep = 1
				keep = sweep_keep
			}
			if attach_suffix[tier] >= keep {
				attach_victim[info.blob] = true
			} else {
				attach_suffix[tier] += 1
			}
		}
		body_suffix: [POLICY_TIERS]int
		for idx in body_order {
			b := bodies[idx]
			if b.protected || body_victim[b.item] || b.item <= anchor do continue
			tier := body_tier(b.size, config.tool_body_small_bytes)
			if tier == 0 do continue
			keep := scaled_keep(body_base_keep(tier), body_pressure_value)
			if config.sweep_aggression > 1 {
				sweep_keep := keep / config.sweep_aggression
				if sweep_keep < 1 do sweep_keep = 1
				keep = sweep_keep
			}
			if body_suffix[tier] >= keep {
				body_victim[b.item] = true
			} else {
				body_suffix[tier] += 1
			}
		}

		low_pct := config.sweep_low_watermark
		attach_low_bytes := (config.attachment_send_budget + recall_extra) * i64(low_pct) / 100
		attach_low_count := config.attachment_max_active * low_pct / 100
		if attach_low_count < 1 do attach_low_count = 1
		for {
			bytes: i64 = 0
			count := 0
			for info in infos {
				if !info.has_active || attach_victim[info.blob] do continue
				bytes += info.size
				if attachment_tier(info.size, config.attachment_small_bytes) != 0 do count += 1
			}
			if bytes <= attach_low_bytes && count <= attach_low_count do break
			added := false
			for i := len(attach_order) - 1; i >= 0; i -= 1 {
				info := infos[attach_order[i]]
				if !info.has_active || info.protected || attach_victim[info.blob] do continue
				if info.first_item <= anchor do continue
				if attachment_tier(info.size, config.attachment_small_bytes) == 0 do continue
				attach_victim[info.blob] = true
				added = true
				break
			}
			if !added do break
		}

		body_low_bytes := (config.tool_body_send_budget + recall_extra) * i64(low_pct) / 100
		for {
			bytes: i64 = 0
			for b in bodies {
				if !body_victim[b.item] do bytes += b.size
			}
			if bytes <= body_low_bytes do break
			added := false
			for i := len(body_order) - 1; i >= 0; i -= 1 {
				b := bodies[body_order[i]]
				if b.protected || body_victim[b.item] || b.item <= anchor do continue
				if body_tier(b.size, config.tool_body_small_bytes) == 0 do continue
				body_victim[b.item] = true
				added = true
				break
			}
			if !added do break
		}
	}

	// Apply attachment victims to every reference of the blob.
	for i in 0 ..< len(items) {
		it := &session.items[i]
		for j in 0 ..< len(it.attachments) {
			att := &it.attachments[j]
			if attach_victim[att.blob] && !att.omitted {
				att.omitted = true
				changed = true
			}
		}
		if body_victim[i] && !it.output_omitted {
			it.output_omitted = true
			changed = true
		}
	}
	if changed {
		notes = fmt.aprintf("pruned old attachment/tool-output payloads (anchor item %d)", anchor)
	}
	return changed, notes
}

// attachments_prepare_and_apply is the turn-boundary entry point. It migrates
// inline data, applies retention, and rewrites the session once if needed.
attachments_prepare_and_apply :: proc(config: ^Config, session: ^Session) -> (changed: bool, notes: string) {
	store := attachment_store_init(session.path)
	defer attachment_store_destroy(&store)
	did_change, err := attachments_externalize(session, &store, config.tool_body_blob_threshold)
	if len(err) > 0 {
		if did_change {
			if rerr := session_rewrite(session); rerr != "" do return did_change, rerr
		}
		return did_change, err
	}
	policy_changed, policy_notes := attachment_policy_apply(config, session)
	did_change = did_change || policy_changed
	if did_change {
		if rerr := session_rewrite(session); rerr != "" {
			return did_change, rerr
		}
	}
	return did_change, policy_notes
}

// attachments_shake omits every attachment and every tool-output body larger
// than body_threshold. It is intentionally unilateral: no age or pressure
// calculation is involved. Blobs stay in the store for recall.
attachments_shake :: proc(
	session: ^Session,
	store: ^Attachment_Store,
	body_threshold: i64,
	blob_threshold: i64,
) -> (
	attachment_count: int,
	attachment_bytes: i64,
	body_count: int,
	body_bytes: i64,
	changed: bool,
	err: string,
) {
	externalize_threshold := min(body_threshold, blob_threshold)
	if externalize_threshold < 0 do externalize_threshold = 0
	migrated, merr := attachments_externalize(session, store, externalize_threshold)
	if len(merr) > 0 do return 0, 0, 0, 0, migrated, merr
	changed = migrated

	for i in 0 ..< len(session.items) {
		it := &session.items[i]
		for j in 0 ..< len(it.attachments) {
			att := &it.attachments[j]
			if att.omitted do continue
			attachment_count += 1
			attachment_bytes += i64(att.size)
			att.omitted = true
			changed = true
		}
		if it.role != "function_call_output" || it.output_omitted do continue
		size := i64(it.output_size)
		if size <= 0 do size = i64(len(it.output))
		if size <= body_threshold do continue
		if len(it.output_blob) == 0 {
			data := transmute([]byte)it.output
			blob, berr := attachment_store_put(store, data)
			if len(berr) > 0 do return attachment_count, attachment_bytes, body_count, body_bytes, changed, berr
			it.output_blob = blob
			it.output_size = len(data)
			delete(it.output)
			it.output = ""
		}
		body_count += 1
		body_bytes += size
		it.output_omitted = true
		changed = true
	}
	return
}

Attachment_Stats :: struct {
	store_bytes:      i64,
	active_unique:    int,
	active_bytes:     i64,
	omitted_unique:   int,
	omitted_bytes:    i64,
	body_active_bytes: i64,
	body_omitted_bytes: i64,
}

attachment_stats :: proc(session: ^Session) -> Attachment_Stats {
	stats := Attachment_Stats{}
	store := attachment_store_init(session.path)
	stats.store_bytes = attachment_store_size(&store)
	attachment_store_destroy(&store)

	active_seen := make(map[string]bool, 16)
	omitted_seen := make(map[string]bool, 16)
	defer {
		for key in active_seen do delete(key)
		delete(active_seen)
		for key in omitted_seen do delete(key)
		delete(omitted_seen)
	}
	for it in session.items {
		for att in it.attachments {
			if len(att.blob) == 0 do continue
			if att.omitted {
				if omitted_seen[att.blob] do continue
				omitted_seen[strings.clone(att.blob)] = true
				stats.omitted_unique += 1
				stats.omitted_bytes += i64(att.size)
			} else {
				if active_seen[att.blob] do continue
				active_seen[strings.clone(att.blob)] = true
				stats.active_unique += 1
				stats.active_bytes += i64(att.size)
			}
		}
		if it.role != "function_call_output" do continue
		size := i64(it.output_size)
		if size <= 0 do size = i64(len(it.output))
		if it.output_omitted {
			stats.body_omitted_bytes += size
		} else {
			stats.body_active_bytes += size
		}
	}
	return stats
}
