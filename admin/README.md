# Admin

It is necessary to set up Firebase project by yourself.

# By default compiles with DDC
pub run build_runner build --output=build

# To compile with dart2js:
pub run build_runner build \
  --define="build_node_compilers|entrypoint=compiler=dart2js" \
  --define="build_node_compilers|entrypoint=dart2js_args=[\"--minify\"]" \ # optional, minifies resulting code
  --output=build/
  
# Run

node build/bin/write_messages.dart.js
    