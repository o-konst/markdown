# Full Document Fixture {#full-doc}

## Task List

- [ ] Unchecked task
- [x] Checked task

## Nested Lists

1. First
   1. Nested first
      1. Deeply nested
2. Second

- Bullet one
- Bullet two

## Table With Alignment

| Left | Center | Right |
| :--- | :---: | ---: |
| a | b | c |
| longer value | x | y |

## Code

```js
function greet(name) {
  return `Hello, ${name}!`
}
```

A fence containing a backtick run:

````text
This fence uses four backticks so a run of three can appear inside: ``` still literal.
````

## Footnote In Context {#footnote-heading}

This paragraph cites a note.[^ctx]

[^ctx]: Context footnote defined near the end of the mixed document.
