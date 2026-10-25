# Named like the compose.yaml service so bake merges both; this file wins.
group "default" {
  targets = ["agents-zoo"]
}

target "agents-zoo" {
  context    = "."
  dockerfile = "Dockerfile"
  tags       = ["agents-zoo:latest"]
  output     = ["type=docker"]
}
