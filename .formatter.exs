spark_locals_without_parens = [
  connection: 1,
  subject_prefix: 1,
  encoder: 1,
  publish?: 1,
  publish: 2,
  publish: 3,
  publish_all: 2,
  publish_all: 3,
  expose: 1,
  expose: 2
]

[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  plugins: [Spark.Formatter],
  import_deps: [:ash, :spark],
  locals_without_parens: spark_locals_without_parens,
  export: [locals_without_parens: spark_locals_without_parens]
]
