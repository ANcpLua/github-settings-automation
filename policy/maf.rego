package main

import rego.v1

expected_as_of := "2026-05-05"

expected_summary := {"stable": 6, "rc": 6, "preview": 18, "alpha": 1, "total": 31}

status_order := ["stable", "rc", "preview", "alpha"]

status_index := {"stable": 0, "rc": 1, "preview": 2, "alpha": 3}

expected_stable := {
	"Microsoft.Agents.AI",
	"Microsoft.Agents.AI.Abstractions",
	"Microsoft.Agents.AI.Foundry",
	"Microsoft.Agents.AI.OpenAI",
	"Microsoft.Agents.AI.Workflows",
	"Microsoft.Agents.AI.Workflows.Generators",
}

expected_active_rc := {
	"Microsoft.Agents.AI.Declarative",
	"Microsoft.Agents.AI.Purview",
	"Microsoft.Agents.AI.Workflows.Declarative",
	"Microsoft.Agents.AI.Workflows.Declarative.Foundry",
}

expected_superseded := {
	"Microsoft.Agents.AI.AzureAI": "Microsoft.Agents.AI.Foundry",
	"Microsoft.Agents.AI.Workflows.Declarative.AzureAI": "Microsoft.Agents.AI.Workflows.Declarative.Foundry",
	"Microsoft.Agents.AI.FoundryMemory": "Microsoft.Agents.AI.Foundry",
}

expected_source_observed := {
	"Microsoft.Agents.AI.Hyperlight",
	"Microsoft.Agents.AI.Hosting.AzureAIResponses",
	"Microsoft.Agents.AI.Mem0",
	"Microsoft.Agents.AI.Workflows.Declarative.Mcp",
}

stable_allowed := "/^\\d+\\.\\d+\\.\\d+$/"

rc_allowed := "/^\\d+\\.\\d+\\.\\d+(?:-[Rr][Cc]\\d+)?$/"

unstable_npm_tokens := ["alpha", "beta", "rc", "preview", "pre", "dev", "canary", "next", "nightly"]

unstable_nuget_tokens := ["alpha", "beta", "preview", "pre", "dev", "experimental", "nightly"]

matrix_names := {p.name | some p in data.packages}

package_by_name[name] := p if {
	some p in data.packages
	name := p.name
}

names_in_status(s) := {p.name | some p in data.packages; p.status == s}

count_in_status(s) := count([p | some p in data.packages; p.status == s])

active_rc_names := {p.name |
	some p in data.packages
	p.status == "rc"
	not p.supersededBy
}

superseded_in_matrix[name] := target if {
	some p in data.packages
	target := p.supersededBy
	name := p.name
}

deny contains msg if {
	data.asOf != expected_as_of
	msg := sprintf("matrix.asOf expected %v, got %v", [expected_as_of, data.asOf])
}

deny contains msg if {
	count(data.packages) != expected_summary.total
	msg := sprintf("published package count expected %v, got %v", [expected_summary.total, count(data.packages)])
}

deny contains msg if {
	some s in status_order
	data.summary[s] != expected_summary[s]
	msg := sprintf("summary.%v expected %v, got %v", [s, expected_summary[s], data.summary[s]])
}

deny contains msg if {
	data.summary.total != expected_summary.total
	msg := sprintf("summary.total expected %v, got %v", [expected_summary.total, data.summary.total])
}

deny contains msg if {
	some s in status_order
	count_in_status(s) != expected_summary[s]
	msg := sprintf("actual %v count expected %v, got %v", [s, expected_summary[s], count_in_status(s)])
}

deny contains msg if {
	some p in data.packages
	not is_string(p.name)
	msg := sprintf("package missing name: %v", [p])
}

deny contains msg if {
	some p in data.packages
	not is_string(p.version)
	msg := sprintf("%v missing version", [p.name])
}

deny contains msg if {
	some p in data.packages
	valid := {"stable", "rc", "preview", "alpha"}
	not p.status in valid
	msg := sprintf("unknown status for %v: %v", [p.name, p.status])
}

deny contains msg if {
	some i, j in numbers.range(0, count(data.packages) - 1)
	i < j
	data.packages[i].name == data.packages[j].name
	msg := sprintf("duplicate package name: %v", [data.packages[i].name])
}

deny contains msg if {
	some i in numbers.range(0, count(data.packages) - 2)
	a := data.packages[i]
	b := data.packages[i + 1]
	not in_order(a, b)
	msg := sprintf("packages not sorted at index %v: %v before %v (status %v before %v)", [i + 1, a.name, b.name, a.status, b.status])
}

in_order(a, b) if status_index[a.status] < status_index[b.status]

in_order(a, b) if {
	status_index[a.status] == status_index[b.status]
	a.name <= b.name
}

deny contains msg if {
	not names_in_status("stable") == expected_stable
	msg := sprintf("stable packages must be exactly %v, got %v", [sort_set(expected_stable), sort_set(names_in_status("stable"))])
}

deny contains msg if {
	some name in expected_stable
	package_by_name[name].version != "1.4.0"
	msg := sprintf("%v expected version 1.4.0, got %v", [name, package_by_name[name].version])
}

deny contains msg if {
	some name in expected_stable
	not regex.match(`^\d+\.\d+\.\d+$`, package_by_name[name].version)
	msg := sprintf("%v must have a stable semver version, got %v", [name, package_by_name[name].version])
}

deny contains msg if {
	count(active_rc_names) != 4
	msg := sprintf("active RC count expected 4, got %v", [count(active_rc_names)])
}

deny contains msg if {
	not active_rc_names == expected_active_rc
	msg := sprintf("active RC packages must be exactly %v, got %v", [sort_set(expected_active_rc), sort_set(active_rc_names)])
}

deny contains msg if {
	some name in expected_active_rc
	package_by_name[name].version != "1.4.0-rc1"
	msg := sprintf("%v expected version 1.4.0-rc1, got %v", [name, package_by_name[name].version])
}

deny contains msg if {
	some name in expected_active_rc
	not regex.match(`^\d+\.\d+\.\d+-[Rr][Cc]\d+$`, package_by_name[name].version)
	msg := sprintf("%v must have an rc semver version, got %v", [name, package_by_name[name].version])
}

deny contains msg if {
	count_in_status("rc") != expected_summary.rc
	msg := sprintf("published RC count expected %v, got %v", [expected_summary.rc, count_in_status("rc")])
}

deny contains msg if {
	some name, target in expected_superseded
	superseded_in_matrix[name] != target
	msg := sprintf("%v supersededBy expected %v, got %v", [name, target, superseded_in_matrix[name]])
}

deny contains msg if {
	some name, _ in superseded_in_matrix
	not expected_superseded[name]
	msg := sprintf("unexpected superseded package: %v", [name])
}

preview_alpha_expected := expected_summary.preview + expected_summary.alpha

preview_alpha_actual := count_in_status("preview") + count_in_status("alpha")

deny contains msg if {
	preview_alpha_actual != preview_alpha_expected
	msg := sprintf("preview/alpha quarantine count expected %v, got %v", [preview_alpha_expected, preview_alpha_actual])
}

deny contains "matrix.sourceObservedPackages must be an array" if not is_array(data.sourceObservedPackages)

source_observed_names := {p.name | some p in data.sourceObservedPackages}

deny contains msg if {
	is_array(data.sourceObservedPackages)
	not source_observed_names == expected_source_observed
	msg := sprintf("source-observed packages must be exactly %v, got %v", [sort_set(expected_source_observed), sort_set(source_observed_names)])
}

deny contains msg if {
	some p in data.sourceObservedPackages
	p.activeNuGetOrgAllowlist != false
	msg := sprintf("%v must set activeNuGetOrgAllowlist: false", [p.name])
}

deny contains msg if {
	some p in data.sourceObservedPackages
	p.name in matrix_names
	msg := sprintf("%v must not be counted in matrix.packages", [p.name])
}

deny contains "platformAutomerge should remain true" if {
	input.platformAutomerge != true
}

deny contains msg if {
	input.prHourlyLimit != 2
	msg := sprintf("prHourlyLimit should remain 2, got %v", [input.prHourlyLimit])
}

deny contains msg if {
	input.prConcurrentLimit != 5
	msg := sprintf("prConcurrentLimit should remain 5, got %v", [input.prConcurrentLimit])
}

maf_stable_idx := i if {
	some i, r in input.packageRules
	r.groupName == "microsoft-agent-framework-stable"
}

maf_rc_idx := i if {
	some i, r in input.packageRules
	r.groupName == "microsoft-agent-framework-rc"
}

maf_quarantine_idx := i if {
	some i, r in input.packageRules
	r.groupName == "microsoft-agent-framework-preview-alpha-quarantine"
}

global_major_idx := i if {
	some i, r in input.packageRules
	is_array(r.matchUpdateTypes)
	"major" in r.matchUpdateTypes
	r.automerge == false
	not r.groupName
}

deny contains "Missing rule: MAF stable allowlist" if not maf_stable_idx

deny contains "Missing rule: MAF active RC allowlist" if not maf_rc_idx

deny contains "Missing rule: MAF preview/alpha quarantine" if not maf_quarantine_idx

deny contains "Missing rule: global major manual-review" if not global_major_idx

maf_stable_rule := input.packageRules[maf_stable_idx]

maf_rc_rule := input.packageRules[maf_rc_idx]

maf_quarantine_rule := input.packageRules[maf_quarantine_idx]

maf_stable_names := {n | some n in maf_stable_rule.matchPackageNames}

maf_rc_names := {n | some n in maf_rc_rule.matchPackageNames}

maf_quarantine_names := {n | some n in maf_quarantine_rule.matchPackageNames}

preview_alpha_pkg_names := {p.name |
	some p in data.packages
	p.status in {"preview", "alpha"}
}

deny contains msg if {
	maf_stable_idx
	not maf_stable_names == expected_stable
	msg := sprintf("MAF stable matchPackageNames mismatch. expected: %v got: %v", [sort_set(expected_stable), sort_set(maf_stable_names)])
}

deny contains msg if {
	maf_stable_idx
	some n in maf_stable_rule.matchPackageNames
	startswith(n, "/")
	msg := sprintf("MAF stable must use exact package names, got regex %v", [n])
}

deny contains "MAF stable must match only the nuget datasource" if {
	maf_stable_idx
	maf_stable_rule.matchDatasources != ["nuget"]
}

deny contains msg if {
	maf_stable_idx
	maf_stable_rule.allowedVersions != stable_allowed
	msg := sprintf("MAF stable allowedVersions expected %v, got %v", [stable_allowed, maf_stable_rule.allowedVersions])
}

deny contains "MAF stable must set automerge: true" if {
	maf_stable_idx
	maf_stable_rule.automerge != true
}

deny contains `MAF stable must set automergeType: "pr"` if {
	maf_stable_idx
	maf_stable_rule.automergeType != "pr"
}

deny contains "MAF stable must not require dashboard approval" if {
	maf_stable_idx
	maf_stable_rule.dependencyDashboardApproval != false
}

deny contains "MAF stable must not combine allowedVersions with matchUpdateTypes" if {
	maf_stable_idx
	"matchUpdateTypes" in object.keys(maf_stable_rule)
}

deny contains msg if {
	maf_rc_idx
	not maf_rc_names == expected_active_rc
	msg := sprintf("MAF active RC matchPackageNames mismatch. expected: %v got: %v", [sort_set(expected_active_rc), sort_set(maf_rc_names)])
}

deny contains msg if {
	maf_rc_idx
	some n in maf_rc_rule.matchPackageNames
	startswith(n, "/")
	msg := sprintf("MAF active RC must use exact package names, got regex %v", [n])
}

deny contains "MAF active RC must match only the nuget datasource" if {
	maf_rc_idx
	maf_rc_rule.matchDatasources != ["nuget"]
}

deny contains "MAF active RC must set ignoreUnstable: false" if {
	maf_rc_idx
	maf_rc_rule.ignoreUnstable != false
}

deny contains "MAF active RC must set respectLatest: false" if {
	maf_rc_idx
	maf_rc_rule.respectLatest != false
}

deny contains msg if {
	maf_rc_idx
	maf_rc_rule.allowedVersions != rc_allowed
	msg := sprintf("MAF active RC allowedVersions expected %v, got %v", [rc_allowed, maf_rc_rule.allowedVersions])
}

deny contains "MAF active RC must set automerge: true" if {
	maf_rc_idx
	maf_rc_rule.automerge != true
}

deny contains `MAF active RC must set automergeType: "pr"` if {
	maf_rc_idx
	maf_rc_rule.automergeType != "pr"
}

deny contains "MAF active RC must not require dashboard approval" if {
	maf_rc_idx
	maf_rc_rule.dependencyDashboardApproval != false
}

deny contains "MAF active RC must not combine allowedVersions with matchUpdateTypes" if {
	maf_rc_idx
	"matchUpdateTypes" in object.keys(maf_rc_rule)
}

deny contains msg if {
	maf_quarantine_idx
	not maf_quarantine_names == preview_alpha_pkg_names
	msg := sprintf("MAF preview/alpha quarantine matchPackageNames mismatch. expected: %v got: %v", [sort_set(preview_alpha_pkg_names), sort_set(maf_quarantine_names)])
}

deny contains msg if {
	maf_quarantine_idx
	some n in maf_quarantine_rule.matchPackageNames
	startswith(n, "/")
	msg := sprintf("MAF preview/alpha quarantine must use exact package names, got regex %v", [n])
}

deny contains "MAF quarantine must match only the nuget datasource" if {
	maf_quarantine_idx
	maf_quarantine_rule.matchDatasources != ["nuget"]
}

deny contains "MAF quarantine must set ignoreUnstable: false" if {
	maf_quarantine_idx
	maf_quarantine_rule.ignoreUnstable != false
}

deny contains "MAF quarantine must set respectLatest: false" if {
	maf_quarantine_idx
	maf_quarantine_rule.respectLatest != false
}

deny contains msg if {
	maf_quarantine_idx
	maf_quarantine_rule.allowedVersions != rc_allowed
	msg := sprintf("MAF quarantine allowedVersions expected %v, got %v", [rc_allowed, maf_quarantine_rule.allowedVersions])
}

deny contains "MAF quarantine must not automerge" if {
	maf_quarantine_idx
	maf_quarantine_rule.automerge != false
}

deny contains "MAF quarantine must require dependency dashboard approval" if {
	maf_quarantine_idx
	maf_quarantine_rule.dependencyDashboardApproval != true
}

deny contains "MAF quarantine must not combine allowedVersions with matchUpdateTypes" if {
	maf_quarantine_idx
	"matchUpdateTypes" in object.keys(maf_quarantine_rule)
}

deny contains msg if {
	global_major_idx
	maf_stable_idx
	maf_stable_idx <= global_major_idx
	msg := sprintf("MAF stable rule (idx %v) must come after global major rule (idx %v)", [maf_stable_idx, global_major_idx])
}

deny contains msg if {
	global_major_idx
	maf_rc_idx
	maf_rc_idx <= global_major_idx
	msg := sprintf("MAF active RC rule (idx %v) must come after global major rule (idx %v)", [maf_rc_idx, global_major_idx])
}

replacement_rules := [r |
	some r in input.packageRules
	is_string(r.replacementName)
]

deny contains msg if {
	some r in replacement_rules
	count(r.matchPackageNames) != 1
	msg := sprintf("replacement rule should target exactly one package: %v", [r.matchPackageNames])
}

replacement_by_source[name] := r if {
	some r in replacement_rules
	count(r.matchPackageNames) == 1
	name := r.matchPackageNames[0]
}

deny contains msg if {
	some from, _ in expected_superseded
	not replacement_by_source[from]
	msg := sprintf("missing replacement rule for %v", [from])
}

deny contains msg if {
	some from, to in expected_superseded
	r := replacement_by_source[from]
	r.replacementName != to
	msg := sprintf("replacement %v expected %v, got %v", [from, to, r.replacementName])
}

deny contains msg if {
	some from, _ in expected_superseded
	r := replacement_by_source[from]
	r.automerge != false
	msg := sprintf("replacement %v must not automerge", [from])
}

deny contains msg if {
	some from, _ in expected_superseded
	r := replacement_by_source[from]
	r.dependencyDashboardApproval != true
	msg := sprintf("replacement %v must require dependency dashboard approval", [from])
}

deny contains msg if {
	some from, _ in expected_superseded
	r := replacement_by_source[from]
	not has_regex_notes(r.prBodyNotes)
	msg := sprintf("replacement %v must document regex customManagers / Version.props rename limitation", [from])
}

has_regex_notes(notes) if {
	is_array(notes)
	some n in notes
	regex.match(`customManagers|custom\.regex|regex-managed|Version\.props`, n)
}

deny contains msg if {
	some i, r in input.packageRules
	r.allowedVersions
	r.matchUpdateTypes
	msg := sprintf("packageRules[%v] combines allowedVersions and matchUpdateTypes", [i])
}

deny contains msg if {
	some i, r in input.packageRules
	some n in r.matchPackageNames
	regex.match(`^/\^Microsoft\\.Agents\\.AI(?:\\.|\\b)`, n)
	r.automerge == true
	msg := sprintf("packageRules[%v] is a broad Microsoft.Agents.AI automerge regex", [i])
}

npm_deny_idx := i if {
	some i, r in input.packageRules
	is_array(r.matchManagers)
	"npm" in r.matchManagers
	is_string(r.allowedVersions)
	startswith(r.allowedVersions, "!/")
}

nuget_deny_idx := i if {
	some i, r in input.packageRules
	is_array(r.matchDatasources)
	"nuget" in r.matchDatasources
	is_string(r.allowedVersions)
	startswith(r.allowedVersions, "!/")
}

deny contains "Missing rule: default-deny unstable npm" if not npm_deny_idx

deny contains "Missing rule: default-deny unstable NuGet" if not nuget_deny_idx

deny contains msg if {
	npm_deny_idx
	some token in unstable_npm_tokens
	not regex.match(sprintf("(?i)%s", [token]), input.packageRules[npm_deny_idx].allowedVersions)
	msg := sprintf("npm default-deny must block %v", [token])
}

deny contains msg if {
	nuget_deny_idx
	some token in unstable_nuget_tokens
	not regex.match(sprintf("(?i)%s", [token]), input.packageRules[nuget_deny_idx].allowedVersions)
	msg := sprintf("NuGet default-deny must block %v", [token])
}

deny contains "NuGet default-deny must not globally block rc" if {
	nuget_deny_idx
	regex.match(`(?i)\brc\b`, input.packageRules[nuget_deny_idx].allowedVersions)
}

deny contains msg if {
	some observed in expected_source_observed
	maf_stable_idx
	observed in maf_stable_rule.matchPackageNames
	msg := sprintf("%v must not appear in active MAF NuGet.org allowlist (stable)", [observed])
}

deny contains msg if {
	some observed in expected_source_observed
	maf_rc_idx
	observed in maf_rc_rule.matchPackageNames
	msg := sprintf("%v must not appear in active MAF NuGet.org allowlist (rc)", [observed])
}

deny contains msg if {
	some observed in expected_source_observed
	maf_quarantine_idx
	observed in maf_quarantine_rule.matchPackageNames
	msg := sprintf("%v must not appear in active MAF NuGet.org quarantine", [observed])
}

sort_set(s) := sort([x | some x in s])
