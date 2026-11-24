from app.repositories.base import BaseRepository, Row


class WishlistRepository(BaseRepository):
    table = "wishlists"

    def __init__(self, client):
        super().__init__(client)

    def find_for_user(self, user_id: str) -> Row | None:
        res = self._run(self.client.table("wishlists").select("*").eq("user_id", user_id).limit(1))
        return res.data[0] if res.data else None

    def create_for_user(self, user_id: str) -> Row:
        return self.create({"user_id": user_id})

    def items(self, wishlist_id: str) -> list[Row]:
        return self._run(self.client.table("wishlist_items").select("*").eq("wishlist_id", wishlist_id).order("created_at", desc=True).order("id")).data

    def find_item(self, wishlist_id: str, item_id: str) -> Row | None:
        res = self._run(self.client.table("wishlist_items").select("*").eq("wishlist_id", wishlist_id).eq("id", item_id).limit(1))
        return res.data[0] if res.data else None

    def find_item_by_product(self, wishlist_id: str, product_id: str) -> Row | None:
        res = self._run(self.client.table("wishlist_items").select("*").eq("wishlist_id", wishlist_id).eq("product_id", product_id).limit(1))
        return res.data[0] if res.data else None

    def add_item(self, values: Row) -> Row:
        return self._run(self.client.table("wishlist_items").insert(values)).data[0]

    def delete_item(self, wishlist_id: str, item_id: str) -> None:
        self._run(self.client.table("wishlist_items").delete().eq("wishlist_id", wishlist_id).eq("id", item_id))
