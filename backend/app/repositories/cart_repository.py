from app.repositories.base import BaseRepository, Row


class CartRepository(BaseRepository):
    table = "carts"

    def __init__(self, client):
        super().__init__(client)

    def find_for_user(self, user_id: str) -> Row | None:
        res = self._run(self.client.table("carts").select("*").eq("user_id", user_id).limit(1))
        return res.data[0] if res.data else None

    def create_for_user(self, user_id: str) -> Row:
        return self.create({"user_id": user_id})

    def items(self, cart_id: str) -> list[Row]:
        return self._run(self.client.table("cart_items").select("*").eq("cart_id", cart_id).order("created_at").order("id")).data

    def find_item(self, cart_id: str, item_id: str) -> Row | None:
        res = self._run(self.client.table("cart_items").select("*").eq("cart_id", cart_id).eq("id", item_id).limit(1))
        return res.data[0] if res.data else None

    def find_item_by_product(self, cart_id: str, product_id: str) -> Row | None:
        res = self._run(self.client.table("cart_items").select("*").eq("cart_id", cart_id).eq("product_id", product_id).limit(1))
        return res.data[0] if res.data else None

    def add_item(self, values: Row) -> Row:
        return self._run(self.client.table("cart_items").insert(values)).data[0]

    def update_item(self, cart_id: str, item_id: str, values: Row) -> Row | None:
        res = self._run(self.client.table("cart_items").update(values).eq("cart_id", cart_id).eq("id", item_id))
        return res.data[0] if res.data else None

    def delete_item(self, cart_id: str, item_id: str) -> None:
        self._run(self.client.table("cart_items").delete().eq("cart_id", cart_id).eq("id", item_id))

    def clear(self, cart_id: str) -> None:
        self._run(self.client.table("cart_items").delete().eq("cart_id", cart_id))
