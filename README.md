# demo-facts-api

This API is hosted at https://demo-facts-api.fly.dev.

It serves as a simple data source for example RAG applications,
supplying facts about various topics.

It serves two endpoints:

## `/topics`

List all the available topics.

```
$ curl "https://demo-facts-api.fly.dev/topics"
["Ikebana","Barcelona","Python","Space"]
```

### `/facts`

Retreive several random facts about a single topic.

```
$ curl "https://demo-facts-api.fly.dev/facts?topic=ikebana&count=3" | jq '.'
[
  {
    "topic": "Ikebana",
    "fact": "Ikebana arrangements are viewed from multiple angles"
  },
  {
    "topic": "Ikebana",
    "fact": "Tatehana was the earliest form of ikebana practiced by priests"
  },
  {
    "topic": "Ikebana",
    "fact": "Seasonal awareness is fundamental to ikebana practice"
  }
]
```