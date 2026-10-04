def path_for($entries; $id; $seen):
  if $id == "" then ""
  elif $id == "trash" or ($seen | index($id)) != null then null
  else $entries[$id] as $entry |
    if $entry == null or $entry.deleted == true then null
    else path_for($entries; ($entry.parent // ""); $seen + [$id]) as $parent |
      if $parent == null then null
      else $parent + "/" + $entry.visibleName end
    end
  end;

[inputs | . + {uuid: (input_filename | split("/") | last | sub("\\.metadata$"; ""))}]
| map({key: .uuid, value: .}) | from_entries as $entries
| [$entries[] |
    select(.type == "DocumentType" and .deleted != true) |
    . as $doc |
    (.visibleName | try capture("^NYT Crosswords (?<start>[0-9]{4}-[0-9]{2}-[0-9]{2}) to (?<end>[0-9]{4}-[0-9]{2}-[0-9]{2})(?:\\.pdf)?$") catch null) as $range |
    select($range != null) |
    {uuid: .uuid, name: .visibleName,
     destination: path_for($entries; (.parent // ""); []),
     start_date: $range.start, end_date: $range.end} |
    select(.destination != null and (.start_date[0:7] == .end_date[0:7]))
  ] as $documents
| $dates[0] | map(. as $date |
    . + {files: [$documents[] |
      select(.destination == $date.destination and
             .start_date <= $date.date and .end_date >= $date.date and
             (.uuid as $id | $pdfs[0] | index($id)) != null)]})
