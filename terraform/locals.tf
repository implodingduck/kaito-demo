locals {
  cluster_name = "kaito${random_string.unique.result}"
  loc_for_naming = lower(replace(var.location, " ", ""))
  loc_short = upper("${substr(local.loc_for_naming,0,1)}${trimprefix(trimprefix(local.loc_for_naming,"east"),"west")}")
  gh_repo = replace(var.gh_repo, "implodingduck/", "")
  tags = {
    "managed_by" = "terraform"
    "repo"       = local.gh_repo
  }
}